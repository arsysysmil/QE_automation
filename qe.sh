#!/bin/bash
#SBATCH --job-name=QE_workflow
#SBATCH --partition=short
#SBATCH --nodes=1
#SBATCH --ntasks=64
#SBATCH --cpus-per-task=1
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.out

# Quantum ESPRESSO workflow.
#
#   sbatch qe.sh case_relax.in           # full pipeline
#   sbatch qe.sh all case_relax.in       # explicit form of the above
#   bash   qe.sh scf case_relax.in       # one step only, for debugging
#   bash   qe.sh dump case_relax.in      # print what the parser sees
#   bash   qe.sh check case_relax.in     # which stages finished, and why not
#
# This file is the orchestrator: it resolves where it lives, loads config.sh
# and lib/, declares which steps exist and in what order, and runs them. The
# steps themselves are in lib/ - one file per concern, so each can be read on
# its own:
#
#   lib/common.sh      environment, per-case paths, diagnostics
#   lib/parser.sh      reading the relax input into cache/parser.cache
#   lib/structure.sh   pulling the relaxed geometry out of the relax output
#   lib/generate.sh    writing the scf / band / nscf inputs
#   lib/run.sh         the steps that launch pw.x, bands.x, dos.x
#   lib/init.sh        detecting the lattice and writing the band path
#
# Steps share state through cache/parser.cache next to the input file, so a
# single step can be re-run on its own after an earlier run produced it.

set -euo pipefail

resolve_root_dir() {
    # Under sbatch the batch script executes from a spooled copy (e.g.
    # /var/spool/slurm/d/job.../slurm_script) whose directory holds neither
    # config.sh nor template/. So the script's own location is tried first
    # (correct for `bash qe.sh ...`), then SLURM_SUBMIT_DIR, which is always
    # the directory sbatch was invoked from. Each candidate is accepted only
    # if config.sh is actually there, rather than assumed.
    local self_dir

    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || self_dir=""

    if [[ -n "$self_dir" && -f "$self_dir/config.sh" ]]; then
        printf '%s' "$self_dir"
        return 0
    fi

    if [[ -n "${SLURM_SUBMIT_DIR:-}" && -f "${SLURM_SUBMIT_DIR}/config.sh" ]]; then
        printf '%s' "$SLURM_SUBMIT_DIR"
        return 0
    fi

    printf '%s' "${self_dir:-$(pwd -P)}"
}

ROOT_DIR="$(resolve_root_dir)"

#############################
# Configuration
#############################

# config.sh holds the knobs meant to be edited (NPROC, BAND_POINTS, ...).
# It stays a separate file on purpose: it is settings, not logic.
if [[ -f "$ROOT_DIR/config.sh" ]]; then
    source "$ROOT_DIR/config.sh"
else
    echo "ERROR: config.sh not found (looked in '$ROOT_DIR')."
    echo "When submitting with sbatch, run it from the directory holding"
    echo "qe.sh and config.sh so SLURM_SUBMIT_DIR points there."
    exit 1
fi

# Pool flag shared by pw.x and bands.x. Post-processing has to use the same
# pool layout as the run that produced the wavefunctions, so this is built
# once and reused rather than set per call.
NPOOL="${NPOOL:-1}"

if ! [[ "$NPOOL" =~ ^[0-9]+$ ]] || (( NPOOL < 1 )); then
    echo "ERROR: NPOOL in config.sh must be a positive integer (got '$NPOOL')"
    exit 1
fi

if (( NPROC % NPOOL != 0 )); then
    echo "ERROR: NPROC ($NPROC) is not divisible by NPOOL ($NPOOL)."
    echo "Pick a NPOOL that divides NPROC evenly, e.g. $(
        for c in 1 2 4 8 16 32; do (( NPROC % c == 0 )) && printf '%s ' "$c"; done)"
    exit 1
fi

POOL_FLAG=""
if (( NPOOL > 1 )); then
    POOL_FLAG="-nk $NPOOL"
fi

#############################
# Library
#############################
#
# Sourced, not run through `bash -c`. That distinction is the whole reason the
# old multi-file layout was merged into one file: each helper was launched as
# its own login shell, which re-sourced /etc/profile and swapped mpirun for one
# that could not launch an Intel-MPI-linked pw.x, and each helper sourced
# config.sh independently so the same setting meant different things in
# different files. Sourcing here keeps one process, one environment, and one
# config.sh - while the code goes back to being readable one file at a time.

for _lib in common parser structure generate run init; do
    if [[ ! -f "$ROOT_DIR/lib/${_lib}.sh" ]]; then
        echo "ERROR: lib/${_lib}.sh not found (looked in '$ROOT_DIR/lib')."
        echo "qe.sh, config.sh and lib/ have to sit in the same directory."
        exit 1
    fi
    source "$ROOT_DIR/lib/${_lib}.sh"
done
unset _lib

#############################
# The steps
#############################
#
# ONE list. `all` runs exactly this, in this order, and the "3/11" counters it
# prints are derived from its length - so adding a stage is adding a line here,
# not renumbering eleven labels and remembering to update two case statements
# that used to list the step names separately.
#
# To add a stage (work function, PDOS, ...):
#   1. write step_<name>() in the lib/ file it belongs to
#   2. add <name> to this list, in the position it runs
# A name with a dash maps to an underscore: gen-scf -> step_gen_scf.

PIPELINE_STEPS=(
    parser
    relax
    extract
    gen-scf
    scf
    gen-band
    band
    bandsx
    gen-nscf
    nscf
    dos
)

# Callable by name, but not part of `all`.
EXTRA_STEPS=( all dump check init )

# Labels for the run header, where the bare step name reads badly.
declare -A STEP_LABELS=(
    [extract]="EXTRACT STRUCTURE"
    [gen-scf]="GENERATE SCF"
    [gen-band]="GENERATE BAND"
    [gen-nscf]="GENERATE NSCF"
    [bandsx]="BANDS.X"
)

# One line of help each, printed by usage().
declare -A STEP_HELP=(
    [parser]="read the input, refresh cache/parser.cache"
    [relax]="run pw.x on the relax input"
    [extract]="pull the relaxed geometry out of the relax output"
    [gen-scf]="write <case>_scf.in"
    [scf]="run pw.x on the scf input"
    [gen-band]="write <case>_band.in"
    [band]="run pw.x on the band input"
    [bandsx]="run bands.x"
    [gen-nscf]="write <case>_nscf.in"
    [nscf]="run pw.x on the nscf input"
    [dos]="run dos.x"
    [dump]="print everything the parser read (debugging)"
    [check]="report which of this case's outputs finished, and why not"
    [init]="detect the lattice and write <case>_band.path"
)

step_function_for() {
    printf 'step_%s' "${1//-/_}"
}

step_label_for() {
    local name="$1"
    printf '%s' "${STEP_LABELS[$name]:-${name^^}}"
}

is_known_step() {
    local candidate
    for candidate in "${PIPELINE_STEPS[@]}" "${EXTRA_STEPS[@]}"; do
        [[ "$candidate" == "$1" ]] && return 0
    done
    return 1
}

usage() {
    local s
    echo "Usage:"
    echo "  qe.sh [step] <case_relax.in> [more_relax.in ...]"
    echo ""
    echo "Several cases in one job run one after another, each getting the whole"
    echo "allocation. A failing case does not stop the others; a summary is printed"
    echo "at the end. Set CASES_PARALLEL > 1 in config.sh to overlap them instead,"
    echo "but read the note there first: overlapping measured far slower here."
    echo ""
    echo "Steps:"
    printf '  %-10s %s\n' "all" "the default: ${PIPELINE_STEPS[*]}"
    for s in "${PIPELINE_STEPS[@]}"; do
        printf '  %-10s %s\n' "$s" "${STEP_HELP[$s]:-}"
    done
    for s in "${EXTRA_STEPS[@]}"; do
        [[ "$s" == "all" ]] && continue
        printf '  %-10s %s\n' "$s" "${STEP_HELP[$s]:-}"
    done
}

#############################
# Argument handling
#############################

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
esac

# A step name never ends in _relax.in, so the two forms are unambiguous:
#   qe.sh a_relax.in b_relax.in        -> step 'all', two cases
#   qe.sh scf a_relax.in b_relax.in    -> step 'scf', two cases
STEP="all"
if [[ "$1" != *_relax.in ]]; then
    STEP="$1"
    shift
fi

if [[ $# -lt 1 ]]; then
    echo "ERROR: no input file given"
    echo ""
    usage
    exit 1
fi

# Everything is validated before any work starts, so a typo in the second
# case does not surface only after the first has run for an hour.
INPUTS=()
for arg in "$@"; do
    if [[ ! -f "$arg" ]]; then
        echo "ERROR: input file not found: $arg (cwd: $(pwd -P))"
        exit 1
    fi

    abs="$(readlink -f "$arg")"

    if [[ "$(basename "$abs")" != *_relax.in ]]; then
        echo "ERROR: input must end with _relax.in: $abs"
        exit 1
    fi

    for seen in ${INPUTS[@]+"${INPUTS[@]}"}; do
        if [[ "$seen" == "$abs" ]]; then
            echo "ERROR: the same input was given twice: $abs"
            exit 1
        fi
    done

    INPUTS+=("$abs")
done

NCASES=${#INPUTS[@]}

if (( NCASES > NPROC )); then
    echo "ERROR: $NCASES cases but only $NPROC MPI ranks; each case needs at least 1."
    exit 1
fi
# Housekeeping: sweep earlier runs' slurm logs into runlogs/ so they stop
# piling up beside the script. The current job's log is left alone, Slurm
# still has it open. Not done with #SBATCH --output=runlogs/... because Slurm
# refuses to start at all when that directory is missing.
mkdir -p "$ROOT_DIR/runlogs"
for old_log in "$ROOT_DIR"/slurm-*.out; do
    [[ -e "$old_log" ]] || continue
    [[ "$old_log" == *"slurm-${SLURM_JOB_ID:-none}.out" ]] && continue
    mv -f "$old_log" "$ROOT_DIR/runlogs/" 2>/dev/null || true
done
# Orchestration
#############################

# Steps are shell functions in this same process, so they inherit the module
# environment directly. The old version had to invoke helpers via `bash -c`
# specifically to avoid a login shell re-sourcing /etc/profile and swapping
# mpirun for one that cannot launch an Intel-MPI-linked pw.x.
run_step() {
    local label="$1"; shift
    local start_ts end_ts

    echo ""
    echo "[$label]"
    echo "  started : $(date '+%Y-%m-%d %H:%M:%S')"
    start_ts=$(date +%s)

    "$@"

    end_ts=$(date +%s)
    echo "  finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  duration: $(format_duration $((end_ts - start_ts)))"
}

step_all() {
    if [[ -n "${SLURM_JOB_ID:-}" ]]; then
        ln -sf "$ROOT_DIR/slurm-${SLURM_JOB_ID}.out" "$LOGS_DIR/pipeline.out"
    fi

    echo "========================================="
    echo "Quantum ESPRESSO Workflow Started"
    echo "Script     : ${BASH_SOURCE[0]}"
    echo "Input      : $INPUT_ABS"
    echo "Case       : $CASE_NAME"
    echo "Work dir   : $INPUT_DIR"
    echo "Logs       : $LOGS_DIR"
    echo "========================================="

    local total=${#PIPELINE_STEPS[@]}
    local i=0 name

    for name in "${PIPELINE_STEPS[@]}"; do
        i=$(( i + 1 ))
        run_step "$i/$total $(step_label_for "$name")" "$(step_function_for "$name")"
    done

    echo ""
    echo "========================================="
    echo "Workflow Finished Successfully"
    echo "========================================="
}

#############################
# Dispatch
#############################

run_one_step() {
    "$(step_function_for "$STEP")"
}

# Reject an unknown step before launching anything, so a typo does not fail
# separately inside every case.
if ! is_known_step "$STEP"; then
    echo "ERROR: unknown step '$STEP'"
    echo ""
    usage
    exit 1
fi

# Every step name in the registry must have a function behind it. Checked once,
# here, so a step added to the list but not yet written fails immediately with
# the reason rather than part-way through a pipeline.
_missing=""
for _s in "${PIPELINE_STEPS[@]}" "${EXTRA_STEPS[@]}"; do
    declare -F "$(step_function_for "$_s")" >/dev/null || _missing+=" $_s"
done
if [[ -n "$_missing" ]]; then
    echo "ERROR: step(s) listed in the registry with no function defined:$_missing"
    echo "Expected e.g. $(step_function_for "${_missing## }")() in one of the lib/ files."
    exit 1
fi
unset _missing _s

if (( NCASES == 1 )); then
    setup_case "${INPUTS[0]}"
    if [[ -n "${SLURM_JOB_ID:-}" ]]; then
        ln -sf "$ROOT_DIR/slurm-${SLURM_JOB_ID}.out" "$LOGS_DIR/pipeline.out"
    fi
    run_one_step
    exit 0
fi

JOB_TAG="${SLURM_JOB_ID:-manual}"
OVERALL_START=$(date +%s)
declare -a CASE_NAMES=() CASE_STATUS=() CASE_LOGS=()
FAILED=0

#############################
# Several cases, one after another (default)
#############################

if (( CASES_PARALLEL <= 1 )); then
    echo "========================================="
    echo "Quantum ESPRESSO Workflow - $NCASES cases, sequential"
    echo "Step        : $STEP"
    echo "Job id      : ${SLURM_JOB_ID:-<none>}"
    echo "Ranks       : $NPROC (each case gets the whole allocation)"
    echo "Pools       : $NPOOL"
    echo "Started     : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================="

    for input_abs in "${INPUTS[@]}"; do
        name="$(basename "$input_abs")"; name="${name%_relax.in}"
        case_start=$(date +%s)

        echo ""
        echo "#########################################"
        echo "# CASE $(( ${#CASE_NAMES[@]} + 1 ))/$NCASES : $name"
        echo "#########################################"

        # Subshell so a failing case ends only itself, and so its per-case
        # variables cannot leak into the next one.
        if ( setup_case "$input_abs"
             if [[ -n "${SLURM_JOB_ID:-}" ]]; then
                 ln -sf "$ROOT_DIR/slurm-${SLURM_JOB_ID}.out" "$LOGS_DIR/pipeline.out"
             fi
             run_one_step ); then
            CASE_STATUS+=("OK")
        else
            CASE_STATUS+=("FAILED")
            FAILED=1
            echo ""
            echo "!!! case $name failed, continuing with the rest"
        fi

        CASE_NAMES+=("$name")
        echo ""
        echo "# case $name took $(format_duration $(( $(date +%s) - case_start )))"
    done

else

#############################
# Several cases at the same time (opt-in, CASES_PARALLEL > 1)
#############################

    RANKS_PER_CASE=$(( NPROC / NCASES ))
    CASE_NPOOL="$(largest_divisor_upto "$RANKS_PER_CASE" "$NPOOL")"

    echo "========================================="
    echo "Quantum ESPRESSO Workflow - $NCASES cases, overlapped"
    echo "Step          : $STEP"
    echo "Job id        : ${SLURM_JOB_ID:-<none>}"
    echo "Total ranks   : $NPROC"
    echo "Ranks per case: $RANKS_PER_CASE"
    echo "Pools per case: $CASE_NPOOL (config NPOOL=$NPOOL)"
    if (( NPROC % NCASES != 0 )); then
        echo "Note          : $NPROC is not divisible by $NCASES,"
        echo "                $(( NPROC - RANKS_PER_CASE * NCASES )) rank(s) idle."
    fi
    echo "Started       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================="
    echo ""

    declare -a CASE_PIDS=()

    for input_abs in "${INPUTS[@]}"; do
        name="$(basename "$input_abs")"; name="${name%_relax.in}"
        case_log="$ROOT_DIR/runlogs/${JOB_TAG}-${name}.log"

        # Each case gets its own log; interleaving several pipelines into one
        # stream makes all of them unreadable.
        (
            export QE_NPROC_OVERRIDE="$RANKS_PER_CASE"
            export QE_NPOOL_OVERRIDE="$CASE_NPOOL"
            source "$ROOT_DIR/config.sh"
            setup_case "$input_abs"
            ln -sf "$case_log" "$LOGS_DIR/pipeline.out"
            run_one_step
        ) > "$case_log" 2>&1 &

        CASE_PIDS+=("$!")
        CASE_NAMES+=("$name")
        CASE_LOGS+=("$case_log")
        echo "launched: $name  (pid $!)  -> $case_log"
    done

    echo ""
    echo "waiting for $NCASES cases..."

    for i in "${!CASE_PIDS[@]}"; do
        if wait "${CASE_PIDS[$i]}"; then
            CASE_STATUS+=("OK")
        else
            CASE_STATUS+=("FAILED")
            FAILED=1
        fi
    done
fi

OVERALL_END=$(date +%s)

echo ""
echo "========================================="
echo "Summary"
echo "========================================="
for i in "${!CASE_NAMES[@]}"; do
    if (( ${#CASE_LOGS[@]} )); then
        printf '  %-10s %-28s %s\n' \
            "${CASE_STATUS[$i]}" "${CASE_NAMES[$i]}" "${CASE_LOGS[$i]}"
    else
        printf '  %-10s %s\n' "${CASE_STATUS[$i]}" "${CASE_NAMES[$i]}"
    fi
done
echo ""
echo "  total wall time: $(format_duration $((OVERALL_END - OVERALL_START)))"
