#!/bin/bash
#SBATCH --job-name=QE_automation
#SBATCH --partition=short
#SBATCH --time=24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=64
#SBATCH --cpus-per-task=1
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.out
#
# --partition and --time are the two lines to size per job, and they are the
# two that decide whether it finishes. There was no --time at all until
# 2026-08-02, which left the limit to whatever default the partition carries -
# a number set by the cluster admins, not visible in this file, and free to
# change without notice. A job that passes it is SIGKILLed.
#
# 24 hours and `short` are a deliberately modest default, not a recommendation:
# they fit a single small case. Ten WS2 cases at ~6.5 h each need three days on
# a partition that allows them.
#
# Override per submission rather than editing this file - command-line flags
# beat #SBATCH, and this file has to stay byte-identical across the three
# copies (see MAINTENANCE.md section 6):
#
#     sbatch -p medium-small -t 3-00:00:00 qe.sh cases/ws2_TS
#
# The limit actually in force is printed in the run header, so it is on the
# first screen of the log rather than buried in the scheduler's settings.

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
#   lib/parser.sh      reading the relax input into cache/<case>.parser.cache
#   lib/structure.sh   pulling the relaxed geometry out of the relax output
#   lib/generate.sh    writing the scf / band / nscf inputs
#   lib/run.sh         the steps that launch pw.x, bands.x, dos.x
#   lib/init.sh        detecting the lattice and writing the band path
#   lib/cif.sh         the structure as CIF, before and after the relax
#
# Steps share state through cache/<case>.parser.cache next to the input file,
# so a single step can be re-run on its own after an earlier run produced it.

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

for _lib in common parser structure generate run init plot cif; do
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
    cif
    gen-scf
    scf
    gen-band
    band
    bandsx
    gen-nscf
    nscf
    dos
    plot
)

# Callable by name, but not part of `all`.
EXTRA_STEPS=( all dump check init )

# The steps that launch pw.x, bands.x or dos.x, and so actually need the
# pseudopotential files to be there. Everything else - parsing, generating an
# input, drawing a figure, reporting on a finished run - works fine without
# them, which matters because inputs are prepared on a laptop where pseudo_dir
# names a path that only exists on the cluster.
MPI_STEPS=( relax scf band bandsx nscf dos )

step_needs_pseudo() {
    local s
    [[ "$1" == "all" ]] && return 0
    for s in "${MPI_STEPS[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

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
    [parser]="read the input, refresh cache/<case>.parser.cache"
    [relax]="run pw.x on the relax input"
    [extract]="pull the relaxed geometry out of the relax output"
    [cif]="write <case>_initial.cif and <case>_relaxed.cif"
    [gen-scf]="write <case>_scf.in"
    [scf]="run pw.x on the scf input"
    [gen-band]="write <case>_band.in"
    [band]="run pw.x on the band input"
    [bandsx]="run bands.x"
    [gen-nscf]="write <case>_nscf.in"
    [nscf]="run pw.x on the nscf input"
    [dos]="run dos.x"
    [plot]="draw the band structure and DOS figures from the data"
    [dump]="print everything the parser read (debugging)"
    [check]="where the last run got to, which outputs finished, and why not"
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
    echo "  qe.sh [step] <case_relax.in | folder> [more ...]"
    echo ""
    echo "A folder argument means every *_relax.in inside it, in name order:"
    echo ""
    echo "    sbatch qe.sh cases/gra        # gra1_relax.in, gra2_relax.in, ..."
    echo "    sbatch qe.sh cases/gra/gra1_relax.in    # just that one"
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
    # A folder argument is an input, not a step name. Without this test
    # `qe.sh cases/gra` - the documented form, and the whole point of folder
    # mode - was read as the step "cases/gra" and then failed with "no input
    # file given", because a directory does not end in _relax.in either.
    #
    # A directory named after a real step (./scf) still resolves to the step;
    # the file form or a trailing slash disambiguates it.
    if ! [[ -d "$1" ]] || is_known_step "$1"; then
        STEP="$1"
        shift
    fi
fi

if [[ $# -lt 1 ]]; then
    echo "ERROR: no input file given"
    echo ""
    usage
    exit 1
fi

# A folder argument stands for every case inside it.
#
# This is the run.sh convention from the cluster - one folder, one job, its
# cases one after another - without the part where you list the files by hand
# and one of them is a typo. Adding a case to the folder adds it to the run;
# there is no second place to keep in step.
#
# Non-recursive on purpose: the folder you name is the folder that runs.
# Sub-folders are separate materials with separate jobs, and a recursive
# sweep would make `qe.sh cases` a full-week accident.
EXPANDED=()
for arg in "$@"; do
    if [[ -d "$arg" ]]; then
        n_found=0
        # Glob order is name order (gra1, gra10, gra2 - not gra1, gra2, gra10).
        for f in "$arg"/*_relax.in; do
            [[ -f "$f" ]] || continue
            EXPANDED+=("$f")
            n_found=$(( n_found + 1 ))
        done

        if (( n_found == 0 )); then
            echo "ERROR: no *_relax.in in folder: $arg"
            echo "       A folder argument runs every case inside it, and this one"
            echo "       holds none. Check the path, or name the input file directly."
            exit 1
        fi

        echo "$arg -> $n_found case(s)"
    else
        EXPANDED+=("$arg")
    fi
done
set -- ${EXPANDED[@]+"${EXPANDED[@]}"}

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

# Two cases in one folder must not share a prefix.
#
# bands.x and dos.x name their output after the prefix, not after the case, so
# two cases sharing one would produce a single <prefix>.dos and a single
# <prefix>.bands.dat.gnu - whichever finished last - while still writing
# per-case gra1_scf.in / gra2_scf.in that make it look as though both are
# there. They would also share <prefix>.save inside outdir.
#
# The parser derives an absent prefix from the case name, so a folder of
# ordinary inputs can never collide. This catches the case that survives that:
# inputs that set prefix explicitly, to the same string. Checked here, against
# the file, because it costs milliseconds and the alternative is finding out
# after the last case overwrites the first one's results.
# get_param() reads INPUT_ABS, so it is set per case here. setup_case() sets it
# again before any step runs, so borrowing it for the preflight is safe - and
# reading the key with the parser's own function rather than a second grep is
# the point: two ways of reading `prefix` would eventually disagree, which is
# the failure mode this project keeps having to fix.
declare -A SEEN_PREFIX=()
declare -a PSEUDO_PROBLEMS=()
declare -A PSEUDO_SEEN=()

for input_abs in "${INPUTS[@]}"; do
    INPUT_ABS="$input_abs"
    case_prefix="$(get_param prefix)"

    # Pseudopotentials, in the same pass. pw.x finds a missing .upf seconds
    # into a job that may have queued for hours; this finds it before the
    # submission, for every case at once, so a folder of ten is fixed in one
    # go rather than one queue wait at a time.
    problem="$(pseudo_problems "$input_abs")"
    [[ -n "$problem" ]] && PSEUDO_PROBLEMS+=("$problem")

    while read -r pseudo_file; do
        [[ -n "$pseudo_file" ]] && PSEUDO_SEEN["$pseudo_file"]=1
    done < <(pseudo_files_of "$input_abs")

    INPUT_ABS="$input_abs"

    if [[ -z "$case_prefix" ]]; then
        case_prefix="$(basename "$input_abs")"
        case_prefix="${case_prefix%_relax.in}"
    fi

    prefix_key="$(dirname "$input_abs")|$case_prefix"

    if [[ -n "${SEEN_PREFIX[$prefix_key]:-}" ]]; then
        echo "ERROR: two cases in $(dirname "$input_abs") share the prefix '$case_prefix':"
        echo "         ${SEEN_PREFIX[$prefix_key]}"
        echo "         $(basename "$input_abs")"
        echo "       bands.x and dos.x name their output after the prefix, so the"
        echo "       second would overwrite the first one's ${case_prefix}.dos and"
        echo "       ${case_prefix}.bands.dat.gnu without saying anything."
        echo "       FIX: give each input its own prefix in &CONTROL - or delete the"
        echo "       prefix line from both, which makes each default to its case name."
        exit 1
    fi

    SEEN_PREFIX[$prefix_key]="$(basename "$input_abs")"
done
unset case_prefix prefix_key problem pseudo_file INPUT_ABS

# Fatal only for the steps that actually launch pw.x.
#
# Preparing inputs on a laptop is a normal part of the workflow, and there
# pseudo_dir names a cluster path that is *supposed* to be absent. Refusing
# `qe.sh dump` or `qe.sh gen-scf` over it would make the tool an obstacle at
# exactly the point it is meant to help.
if (( ${#PSEUDO_PROBLEMS[@]} )); then
    if step_needs_pseudo "$STEP"; then
        echo "ERROR: pseudopotential files are missing for" \
             "${#PSEUDO_PROBLEMS[@]} of $NCASES case(s)."
        echo ""
        printf '%s\n\n' "${PSEUDO_PROBLEMS[@]}"
        echo "  pw.x would find this a few seconds into the run, after the queue"
        echo "  wait. Fix the pseudo_dir line or copy the files in, then submit."
        echo "  Steps that do not launch pw.x (parser, dump, gen-scf, plot, check)"
        echo "  run regardless - this only blocks the ones that need the files."
        exit 1
    fi

    echo "note: pseudopotential files are missing for" \
         "${#PSEUDO_PROBLEMS[@]} of $NCASES case(s)."
    echo ""
    printf '%s\n\n' "${PSEUDO_PROBLEMS[@]}"
    echo "  '$STEP' does not launch pw.x, so this is not in its way. Normal when"
    echo "  preparing inputs on a laptop against a pseudo_dir that lives on the"
    echo "  cluster. The steps that do run pw.x will refuse until it resolves."
    echo ""
elif step_needs_pseudo "$STEP"; then
    echo "pseudopotentials: $NCASES case(s), ${#PSEUDO_SEEN[@]} distinct file(s), all present"
fi

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
# The step currently in flight, for the traps below. Empty between steps, so a
# trap that fires with these set means the run died *inside* a step rather than
# between them.
CURRENT_STEP_NAME=""
CURRENT_STEP_INDEX=""
CURRENT_STEP_TOTAL=""
CURRENT_STEP_START=""

# Most step functions report a problem with `exit 1` rather than `return 1`,
# so a failing step takes the whole shell down and never reaches any code
# after the call. That is why the outcome is recorded from an EXIT trap
# instead of after the step returns: the trap runs on the way out no matter
# which of the twelve steps decided to leave.
on_exit() {
    local rc=$?
    [[ -n "$CURRENT_STEP_NAME" ]] || return 0

    status_mark "$CURRENT_STEP_INDEX" "$CURRENT_STEP_TOTAL" "$CURRENT_STEP_NAME" \
                FAILED "$(format_duration $(( $(date +%s) - CURRENT_STEP_START )))"

    echo ""
    echo "  STOPPED at step $CURRENT_STEP_INDEX/$CURRENT_STEP_TOTAL" \
         "($CURRENT_STEP_NAME) after" \
         "$(format_duration $(( $(date +%s) - CURRENT_STEP_START )))," \
         "exit $rc."
    echo "  The reason is printed above. Steps before this one finished and left"
    echo "  their outputs in place; nothing after it ran."
    echo "  Full history:  bash qe.sh check $INPUT_NAME"

    CURRENT_STEP_NAME=""
}

# Slurm sends SIGTERM before SIGKILL when a job hits its time limit or is
# scancel'd, so there is usually a moment to say what was running. When there
# is not - SIGKILL, OOM killer, a node dropping off the network - the RUNNING
# line that status_mark wrote before the step started is still on disk, and
# `qe.sh check` reads the interruption off that instead.
on_signal() {
    local sig="$1"

    if [[ -n "$CURRENT_STEP_NAME" ]]; then
        status_mark "$CURRENT_STEP_INDEX" "$CURRENT_STEP_TOTAL" "$CURRENT_STEP_NAME" \
                    INTERRUPTED "$(format_duration $(( $(date +%s) - CURRENT_STEP_START )))"
        echo ""
        echo "!!! SIG$sig while running step" \
             "$CURRENT_STEP_INDEX/$CURRENT_STEP_TOTAL ($CURRENT_STEP_NAME)."
        echo "    Walltime, scancel or the node going away. Nothing after this ran."
        CURRENT_STEP_NAME=""
    else
        echo ""
        echo "!!! SIG$sig received between steps."
    fi

    trap - EXIT
    exit $(( 128 + ${2:-15} ))
}

install_traps() {
    trap on_exit EXIT
    trap 'on_signal TERM 15' TERM
    trap 'on_signal INT   2' INT
}

# What the scheduler will actually enforce, asked of it rather than assumed.
# Empty off the cluster.
slurm_limits() {
    [[ -n "${SLURM_JOB_ID:-}" ]] || return 0
    command -v squeue >/dev/null 2>&1 || return 0

    local line
    line="$(squeue -h -j "$SLURM_JOB_ID" -o '%P|%l' 2>/dev/null || true)"
    [[ -n "$line" ]] || return 0

    printf 'Partition   : %s\n' "${line%%|*}"
    printf 'Time limit  : %s\n' "${line##*|}"
}

run_step() {
    local idx="$1" total="$2" name="$3"
    local start_ts end_ts

    echo ""
    echo "[$idx/$total $(step_label_for "$name")]"
    echo "  started : $(date '+%Y-%m-%d %H:%M:%S')"
    start_ts=$(date +%s)

    CURRENT_STEP_NAME="$name"
    CURRENT_STEP_INDEX="$idx"
    CURRENT_STEP_TOTAL="$total"
    CURRENT_STEP_START="$start_ts"
    status_mark "$idx" "$total" "$name" RUNNING

    "$(step_function_for "$name")"

    end_ts=$(date +%s)
    CURRENT_STEP_NAME=""
    status_mark "$idx" "$total" "$name" OK "$(format_duration $((end_ts - start_ts)))"

    echo "  finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  duration: $(format_duration $((end_ts - start_ts)))"
}

step_all() {
    if [[ -n "${SLURM_JOB_ID:-}" ]]; then
        ln -sf "$ROOT_DIR/slurm-${SLURM_JOB_ID}.out" "$LOGS_DIR/${CASE_NAME}.pipeline.out"
    fi

    echo "========================================="
    echo "Quantum ESPRESSO Workflow Started"
    echo "Script     : ${BASH_SOURCE[0]}"
    echo "Input      : $INPUT_ABS"
    echo "Case       : $CASE_NAME"
    echo "Work dir   : $INPUT_DIR"
    echo "Logs       : $LOGS_DIR"
    slurm_limits
    echo "========================================="

    local total=${#PIPELINE_STEPS[@]}
    local i=0 name

    status_begin "$total"

    for name in "${PIPELINE_STEPS[@]}"; do
        i=$(( i + 1 ))
        run_step "$i" "$total" "$name"
    done

    echo ""
    echo "========================================="
    echo "Workflow Finished Successfully"
    echo "========================================="
}

#############################
# Dispatch
#############################

# A single pipeline step gets the same bookkeeping as a full run - it can be
# the one that takes six hours. dump/check/init are excluded: they read state,
# they do not advance it, and recording them would overwrite the record of the
# run being investigated.
run_one_step() {
    local s
    for s in "${PIPELINE_STEPS[@]}"; do
        if [[ "$s" == "$STEP" ]]; then
            status_begin 1
            run_step 1 1 "$STEP"
            return 0
        fi
    done

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
    install_traps
    if [[ -n "${SLURM_JOB_ID:-}" ]]; then
        ln -sf "$ROOT_DIR/slurm-${SLURM_JOB_ID}.out" "$LOGS_DIR/${CASE_NAME}.pipeline.out"
    fi
    run_one_step
    trap - EXIT
    exit 0
fi

JOB_TAG="${SLURM_JOB_ID:-manual}"
OVERALL_START=$(date +%s)
declare -a CASE_NAMES=() CASE_STATUS=() CASE_LOGS=() CASE_STOPPED_AT=()
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
    slurm_limits
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
        # variables cannot leak into the next one. The traps are installed
        # inside it, not outside: bash resets a parent's traps in a subshell,
        # so an EXIT trap set out here would never fire for the step that
        # actually failed.
        if ( setup_case "$input_abs"
             install_traps
             if [[ -n "${SLURM_JOB_ID:-}" ]]; then
                 ln -sf "$ROOT_DIR/slurm-${SLURM_JOB_ID}.out" "$LOGS_DIR/${CASE_NAME}.pipeline.out"
             fi
             run_one_step
             trap - EXIT ); then
            CASE_STATUS+=("OK")
            CASE_STOPPED_AT+=("")
        else
            CASE_STATUS+=("FAILED")
            CASE_STOPPED_AT+=("$(status_last_step "$input_abs")")
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
    slurm_limits
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
            install_traps
            ln -sf "$case_log" "$LOGS_DIR/${CASE_NAME}.pipeline.out"
            run_one_step
            trap - EXIT
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
            CASE_STOPPED_AT+=("")
        else
            CASE_STATUS+=("FAILED")
            CASE_STOPPED_AT+=("$(status_last_step "${INPUTS[$i]}")")
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
    stopped="${CASE_STOPPED_AT[$i]:-}"
    [[ -n "$stopped" ]] && stopped="stopped at $stopped"

    if (( ${#CASE_LOGS[@]} )); then
        printf '  %-10s %-24s %-20s %s\n' \
            "${CASE_STATUS[$i]}" "${CASE_NAMES[$i]}" "$stopped" "${CASE_LOGS[$i]}"
    else
        printf '  %-10s %-24s %s\n' \
            "${CASE_STATUS[$i]}" "${CASE_NAMES[$i]}" "$stopped"
    fi
done
echo ""
echo "  total wall time: $(format_duration $((OVERALL_END - OVERALL_START)))"

if (( FAILED )); then
    echo ""
    echo "  For the full history of a failed case:"
    for i in "${!CASE_NAMES[@]}"; do
        [[ "${CASE_STATUS[$i]}" == FAILED ]] || continue
        echo "    bash qe.sh check ${INPUTS[$i]}"
    done
fi

# Exit non-zero when any case failed.
#
# FAILED was set here from the start but never read, so the last command of the
# script was the wall-time echo and it returned 0 however many cases had died.
# On the cluster that meant sacct showed COMPLETED 0:0 for a job half of whose
# cases failed, and `sbatch --dependency=afterok` on it would launch the next
# stage regardless. README promised this exit code; now it is produced.
exit "$FAILED"
