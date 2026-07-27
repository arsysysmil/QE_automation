#!/bin/bash
#SBATCH --job-name=QE_workflow
#SBATCH --partition=short
#SBATCH --nodes=1
#SBATCH --ntasks=64
#SBATCH --cpus-per-task=1
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.out

# Quantum ESPRESSO workflow, single-file edition.
#
#   sbatch qe.sh case_relax.in           # full pipeline (same as before)
#   sbatch qe.sh all case_relax.in       # explicit form of the above
#   bash   qe.sh scf case_relax.in       # one step only, for debugging
#   bash   qe.sh dump case_relax.in      # print what the parser sees
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

usage() {
    cat <<'USAGE'
Usage:
  qe.sh [step] <case_relax.in> [more_relax.in ...]

Several cases in one job run one after another, each getting the whole
allocation. A failing case does not stop the others; a summary is printed
at the end. Set CASES_PARALLEL > 1 in config.sh to overlap them instead,
but read the note there first: overlapping measured far slower here.

Steps:
  all              relax -> scf -> band -> bands.x -> nscf -> dos   (default)
  parser           read the input, refresh cache/parser.cache
  dump             print parsed values (debugging)
  relax            run pw.x on the relax input
  extract          pull relaxed geometry out of the relax output
  gen-scf          write <case>_scf.in
  scf              run pw.x on the scf input
  gen-band         write <case>_band.in
  band             run pw.x on the band input
  bandsx           run bands.x
  gen-nscf         write <case>_nscf.in
  nscf             run pw.x on the nscf input
  dos              run dos.x
USAGE
}

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

MODULES_LOADED=0

# Environment setup for the MPI steps.
#
# Deliberately one code path for both machines instead of a separate laptop
# copy of this script. This project already suffers from three copies that
# drifted apart; a fourth, differing only in how pw.x is found, would be the
# same mistake again. What differs between a cluster and a laptop is settings,
# so it lives in config.sh (QE_MODULES) - not here.
load_modules() {
    [[ $MODULES_LOADED -eq 1 ]] && return 0

    # `module` is a shell function on Lmod/environment-modules, not a binary,
    # so `command -v` alone is not enough to detect it.
    if [[ "$(type -t module 2>/dev/null)" == "function" ]] || command -v module >/dev/null 2>&1; then
        module purge
        local m
        for m in ${QE_MODULES:-}; do
            module load "$m"
        done
    elif [[ -n "${QE_MODULES:-}" ]]; then
        echo "  note: no 'module' command here - ignoring QE_MODULES and taking"
        echo "        pw.x from PATH ($(command -v pw.x 2>/dev/null || echo 'not found'))"
    fi

    if ! command -v "${PW%% *}" >/dev/null 2>&1; then
        echo "ERROR: '${PW%% *}' is not on PATH after environment setup."
        if [[ -n "${QE_MODULES:-}" ]]; then
            echo "       Modules tried: $QE_MODULES"
        fi
        echo "       On a machine without modules, install Quantum ESPRESSO or put"
        echo "       its bin/ on PATH before running the MPI steps."
        exit 1
    fi

    export OMP_NUM_THREADS=1

    # Locking memory is a cluster privilege; a laptop refuses, and that is not
    # a reason to stop.
    ulimit -l unlimited 2>/dev/null || true

    MODULES_LOADED=1
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

# Per-case state. Every step function reads these, so they are (re)set once
# per case rather than computed at the top for a single fixed input.
setup_case() {
    INPUT_ABS="$1"
    INPUT_DIR="$(dirname "$INPUT_ABS")"
    INPUT_NAME="$(basename "$INPUT_ABS")"
    CASE_NAME="${INPUT_NAME%_relax.in}"

    CACHE_DIR="$INPUT_DIR/cache"
    LOGS_DIR="$INPUT_DIR/logs"
    STRUCTURE_FILE="$CACHE_DIR/structure.in"
    CACHE_FILE="$CACHE_DIR/parser.cache"

    RELAX_IN="$INPUT_ABS"
    RELAX_OUT="$INPUT_DIR/${CASE_NAME}_relax.out"
    SCF_IN="$INPUT_DIR/${CASE_NAME}_scf.in"
    SCF_OUT="$INPUT_DIR/${CASE_NAME}_scf.out"
    BAND_IN="$INPUT_DIR/${CASE_NAME}_band.in"
    BAND_OUT="$INPUT_DIR/${CASE_NAME}_band.out"
    NSCF_IN="$INPUT_DIR/${CASE_NAME}_nscf.in"
    NSCF_OUT="$INPUT_DIR/${CASE_NAME}_nscf.out"
    BAND_PATH_FILE="$INPUT_DIR/${CASE_NAME}_band.path"

    mkdir -p "$CACHE_DIR" "$LOGS_DIR" "$INPUT_DIR/work"
}

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

#############################
# Small helpers
#############################

format_duration() {
    local secs="$1"
    printf '%dh%dm%ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

# Largest divisor of $1 that does not exceed $2. Used to fit the configured
# NPOOL into however many ranks a case actually gets: pw.x requires the rank
# count to be divisible by the pool count.
largest_divisor_upto() {
    local n="$1" cap="$2" d
    for (( d = cap; d >= 1; d-- )); do
        if (( n % d == 0 )); then
            printf '%s' "$d"
            return 0
        fi
    done
    printf '1'
}

# Turn the more opaque QE aborts into something actionable. These are the
# failures whose message does not point at its own cause.
diagnose_failure() {
    local outfile="$1"

    if grep -q "wrong record length" "$outfile" 2>/dev/null; then
        echo ""
        echo "  DIAGNOSIS: 'wrong record length' from diropn means a rank ended up"
        echo "  with zero plane waves, so the wavefunction record length nbnd*npwx"
        echo "  came out 0. It happens when NPROC ($NPROC) is large relative to the"
        echo "  size of the cell - nothing to do with the pseudopotential, though a"
        echo "  low cutoff makes it more likely by reducing the plane-wave count."
        echo "  FIX: raise NPOOL in config.sh (currently $NPOOL), or lower NPROC."
        if grep -q "no G-vectors" "$outfile" 2>/dev/null; then
            echo "  Confirmed: QE also reported 'some processors have no G-vectors'."
        fi
        echo ""
        return
    fi

    if grep -qE "some pools have no k-?points|npool.*too large" "$outfile" 2>/dev/null; then
        echo ""
        echo "  DIAGNOSIS: NPOOL ($NPOOL) exceeds the number of k-points in this"
        echo "  calculation, leaving some pools with nothing to do."
        echo "  FIX: lower NPOOL in config.sh (1 disables pooling entirely)."
        echo ""
        return
    fi

    if grep -q "not found" "$outfile" 2>/dev/null && grep -qi "readpp\|upf" "$outfile" 2>/dev/null; then
        echo ""
        echo "  DIAGNOSIS: a pseudopotential file named in ATOMIC_SPECIES is not"
        echo "  present in pseudo_dir."
        echo ""
        return
    fi
}

check_done() {
    local outfile="$1"
    local label="$2"

    if [[ ! -f "$outfile" ]]; then
        echo "ERROR: output file not found: $outfile"
        exit 1
    fi

    if ! grep -q "JOB DONE." "$outfile"; then
        echo "ERROR: $label did not finish cleanly."
        diagnose_failure "$outfile"
        echo "Last lines of $outfile:"
        tail -n 40 "$outfile" || true
        exit 1
    fi

    echo "SUCCESS : $outfile"
}

require_cache() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        echo "ERROR: $CACHE_FILE not found - run the 'parser' step first."
        exit 1
    fi
    source "$CACHE_FILE"

    # A cache from an older qe.sh has no CONTROL_EXTRA/SYSTEM_EXTRA fields.
    # Sourcing it anyway would run with the passthrough quietly empty, which
    # is indistinguishable from the passthrough being broken - so rebuild.
    if [[ "${CACHE_VERSION:-0}" != "$CACHE_VERSION_EXPECTED" ]]; then
        echo "  note: $CACHE_FILE was written by an older qe.sh" \
             "(v${CACHE_VERSION:-0}, expected v${CACHE_VERSION_EXPECTED}) - refreshing it"
        step_parser
        source "$CACHE_FILE"
    fi
}

require_structure() {
    if [[ ! -f "$STRUCTURE_FILE" ]]; then
        echo "ERROR: $STRUCTURE_FILE not found - run the 'extract' step first."
        exit 1
    fi
}

#############################
# Step: parser
#############################

get_param() {
    local key="$1"
    grep -iE "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_ABS" \
        | head -1 \
        | sed -E "s/^[^=]*=[[:space:]]*//; s/[',]//g; s/[[:space:]]+$//" \
        || true
}

# Everything the input declares inside one namelist, minus the keys this
# script writes itself.
#
# Without this only the 16 keys get_param() knows about survived into the
# generated scf/band/nscf inputs, and everything else was dropped in silence:
# nbnd, nspin, starting_magnetization, vdw_corr, tefield/dipfield, edir,
# tot_charge, input_dft, assume_isolated... A MoS2 input with
# vdw_corr='DFT-D3' therefore produced an SCF *without* the dispersion
# correction, and the nspin=2 NO2 input produced a non-magnetic band
# structure. Same failure mode as the nbnd=120 bug: no error, different
# physics.
#
# Copied as raw lines rather than parsed into variables, so indexed keys
# (starting_magnetization(1) = 0.5) and forms this script has never heard of
# come through untouched.
namelist_passthrough() {
    local nml_pat="$1"   # lowercase, e.g. '^[ \t]*&system[ \t]*$'
    local drop_keys="$2" # alternation, e.g. 'ibrav|nat|ntyp'

    awk -v pat="$nml_pat" '
    { raw = $0; sub(/!.*/, "", raw); low = tolower(raw) }
    !inside && low ~ pat { inside = 1; next }
    inside && raw ~ /^[[:space:]]*(\/|&[Ee][Nn][Dd])[[:space:]]*$/ { exit }
    inside { print raw }
    ' "$INPUT_ABS" \
        | grep -viE "^[[:space:]]*(${drop_keys})[[:space:]]*(\([^)]*\))?[[:space:]]*=" \
        | grep -vE "^[[:space:]]*$" \
        || true
}

# Keys the generator writes itself, so passing them through as well would
# duplicate them inside the namelist.
#
# &CONTROL additionally drops the relax-only ones: restart_mode would make a
# fresh scf try to restart, and nstep/etot_conv_thr/forc_conv_thr mean nothing
# outside a relax. tefield/dipfield are deliberately NOT dropped - they belong
# with edir/emaxpos/eopreg/eamp in &SYSTEM, and keeping only half of that pair
# turns the dipole correction off without saying so.
DROP_CONTROL='calculation|prefix|outdir|pseudo_dir|restart_mode|nstep|etot_conv_thr|forc_conv_thr'

# celldm/A/B/C/cosAB/cosAC/cosBC are dropped because the lattice now comes
# from cache/structure.in as an explicit CELL_PARAMETERS block; leaving a
# second, stale definition of the same cell in &SYSTEM is how they disagree.
DROP_SYSTEM='ibrav|nat|ntyp|ecutwfc|ecutrho|occupations|smearing|degauss|celldm|a|b|c|cosab|cosac|cosbc'

DROP_ELECTRONS='conv_thr|mixing_beta'

# Cards worth carrying from the relax input into every generated input, in
# the order they appear. A card runs from its header to the next card header
# or end of file; blank lines inside it are kept, trailing ones trimmed.
CARDS_KEPT='HUBBARD|OCCUPATIONS'

# Every card name pw.x knows, so the end of one card can be recognised
# without knowing which card comes next.
CARDS_ALL='ATOMIC_SPECIES|ATOMIC_POSITIONS|K_POINTS|CELL_PARAMETERS|HUBBARD|OCCUPATIONS|CONSTRAINTS|ATOMIC_VELOCITIES|ATOMIC_FORCES|ADDITIONAL_K_POINTS|SOLVENTS'

extract_cards() {
    local infile="$1"

    awk -v keep="^[[:space:]]*($CARDS_KEPT)([[:space:]]|\\\\(|\\\\{|$)" \
        -v any="^[[:space:]]*($CARDS_ALL)([[:space:]]|\\\\(|\\\\{|$)" '
    $0 ~ any { copying = ($0 ~ keep) }
    copying  { print }
    ' "$infile" \
        | sed -E '$ { /^[[:space:]]*$/ d; }'
}

announce_passthrough() {
    local nml="$1" block="$2"
    [[ -z "$block" ]] && return 0
    echo "  passthrough &${nml}: $(
        printf '%s\n' "$block" \
            | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=.*//' \
            | tr '\n' ' ')"
}

# Bumped whenever the cache gains a field, so a cache written by an older
# qe.sh is rebuilt instead of silently sourced with the new fields missing -
# which would look exactly like the passthrough not working.
# Kept under a different name from the CACHE_VERSION the cache file itself
# sets, because sourcing the cache would otherwise overwrite the value it is
# about to be compared against.
CACHE_VERSION_EXPECTED='3'

step_parser() {
    local PREFIX OUTDIR PSEUDO_DIR CALCULATION
    local IBRAV NAT NTYP ECUTWFC ECUTRHO
    local OCCUPATIONS SMEARING DEGAUSS CONV_THR MIXING_BETA CELL_DOFREE
    local ATOMIC_SPECIES_BLOCK K_POINTS_LINE K_POINTS_MODE EXTRA_CARDS_BLOCK
    local CONTROL_EXTRA_BLOCK SYSTEM_EXTRA_BLOCK ELECTRONS_EXTRA_BLOCK

    PREFIX=$(get_param prefix);   [[ -z "$PREFIX" ]] && PREFIX="pwscf"
    OUTDIR=$(get_param outdir);   [[ -z "$OUTDIR" ]] && OUTDIR="./work"

    PSEUDO_DIR=$(get_param pseudo_dir)
    CALCULATION=$(get_param calculation)

    IBRAV=$(get_param ibrav)
    NAT=$(get_param nat)
    NTYP=$(get_param ntyp)
    ECUTWFC=$(get_param ecutwfc)
    ECUTRHO=$(get_param ecutrho)
    OCCUPATIONS=$(get_param occupations)
    SMEARING=$(get_param smearing)
    DEGAUSS=$(get_param degauss)

    # Values the input omits fall back to config.sh's DEFAULT_* entries.
    # Those names are deliberately namespaced: the old layout used bare
    # SMEARING/DEGAUSS/MIXING_BETA in config.sh, which then overwrote the
    # values parsed from the input file whenever config.sh was sourced last.
    CONV_THR=$(get_param conv_thr)
    if [[ -z "$CONV_THR" ]]; then
        CONV_THR="${DEFAULT_CONV_THR:-1.0d-6}"
        echo "  note: conv_thr absent from input, using default $CONV_THR"
    fi

    MIXING_BETA=$(get_param mixing_beta)
    if [[ -z "$MIXING_BETA" ]]; then
        MIXING_BETA="${DEFAULT_MIXING_BETA:-0.7}"
        echo "  note: mixing_beta absent from input, using default $MIXING_BETA"
    fi

    # Tells the nscf step whether this is a 2D slab or a normal 3D cell.
    CELL_DOFREE=$(get_param cell_dofree)

    # Stops at a blank line OR at the next card header. Blank-line-only was
    # too fragile: an input whose ATOMIC_SPECIES card is followed directly by
    # ATOMIC_POSITIONS, with no blank line between them, had the whole
    # positions card swallowed into the species list - and the generated
    # inputs then carried a mangled ATOMIC_SPECIES that QE rejected with an
    # error pointing nowhere near the real cause.
    ATOMIC_SPECIES_BLOCK=$(awk -v any="^[[:space:]]*($CARDS_ALL)([[:space:]]|\\\\(|\\\\{|$)" '
    /^[[:space:]]*ATOMIC_SPECIES[[:space:]]*$/ {flag=1; next}
    flag && /^[[:space:]]*$/ {exit}
    flag && $0 ~ any {exit}
    flag {print}
    ' "$INPUT_ABS")

    # The card's own mode word decides how the k-points may be handled later:
    # 'automatic' is a mesh that the nscf step can scale, 'gamma' is a single
    # point that must be reproduced verbatim, and an explicit list cannot be
    # scaled at all. Reading only the line *after* the header, as this did,
    # made a gamma-only molecule look like a missing K_POINTS card.
    K_POINTS_MODE=$(grep -iE "^[[:space:]]*K_POINTS" "$INPUT_ABS" \
        | head -1 \
        | sed -E 's/^[[:space:]]*[Kk]_[Pp][Oo][Ii][Nn][Tt][Ss][[:space:]]*//; s/[{}()]//g; s/!.*//; s/[[:space:]]//g' \
        | tr 'A-Z' 'a-z')

    # QE's own default when the mode word is omitted.
    [[ -z "$K_POINTS_MODE" ]] && K_POINTS_MODE="tpiba"

    K_POINTS_LINE=""
    if [[ "$K_POINTS_MODE" == "automatic" ]]; then
        K_POINTS_LINE=$(awk '
        /^[[:space:]]*K_POINTS[[:space:]]*/ {
            getline
            sub(/!.*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print
            exit
        }
        ' "$INPUT_ABS")
    fi

    # Cards other than the four this script builds itself. HUBBARD is the one
    # that matters: DFT+U is written as a card in QE 7.x, not as &SYSTEM keys,
    # so it was dropped after the relax and every later step ran plain PBE -
    # an antiferromagnetic insulator like NiO comes out metallic, silently.
    # OCCUPATIONS carries an explicit per-band occupation list.
    #
    # CONSTRAINTS / ATOMIC_VELOCITIES / ATOMIC_FORCES are deliberately not
    # carried: they only mean something to a relax or an MD run.
    EXTRA_CARDS_BLOCK=$(extract_cards "$INPUT_ABS")

    if [[ -z "$PSEUDO_DIR" ]]; then
        echo "ERROR: pseudo_dir not found in $INPUT_ABS"
        exit 1
    fi

    local var
    for var in NAT NTYP ECUTWFC IBRAV; do
        if [[ -z "${!var}" ]]; then
            echo "ERROR: $var not found in $INPUT_ABS"
            if [[ "$var" == "IBRAV" ]]; then
                echo "       Add 'ibrav = 0' to &SYSTEM. It used to be copied through"
                echo "       empty, producing 'ibrav =' in the generated inputs and a"
                echo "       namelist read error from pw.x three steps later."
            fi
            exit 1
        fi
    done

    # The geometry is handed between steps as an explicit CELL_PARAMETERS
    # card, which only exists for ibrav = 0. Any other value describes the
    # lattice through celldm/A/B/C instead, and there is nothing to extract.
    # Caught here rather than in step_extract so it costs seconds, not a relax.
    if [[ "$IBRAV" != "0" ]]; then
        echo "ERROR: ibrav = $IBRAV in $INPUT_ABS, but this pipeline needs ibrav = 0."
        echo "       Steps pass the geometry to each other as a CELL_PARAMETERS"
        echo "       card, which an ibrav /= 0 input does not have."
        echo "       FIX: set ibrav = 0 and write the three lattice vectors as an"
        echo "       explicit CELL_PARAMETERS card."
        exit 1
    fi

    # QE itself treats a missing `occupations` as 'fixed', so rejecting an
    # input that omits it would be stricter than QE. 'fixed' is only right for
    # a system with a gap; a metal needs occupations='smearing' spelled out.
    if [[ -z "$OCCUPATIONS" ]]; then
        OCCUPATIONS="${DEFAULT_OCCUPATIONS:-fixed}"
        echo "  note: occupations absent from input, using default '$OCCUPATIONS'"
        echo "        (correct for insulators/semiconductors; a metal needs"
        echo "         occupations='smearing' set explicitly)"
    fi

    # smearing/degauss only mean anything when occupations actually smears;
    # 'fixed' and 'tetrahedra*' legitimately omit them, and must keep them
    # empty so they are not emitted into the generated inputs at all.
    if [[ "${OCCUPATIONS,,}" == "smearing" ]]; then
        if [[ -z "$SMEARING" ]]; then
            SMEARING="${DEFAULT_SMEARING:-mv}"
            echo "  note: smearing absent from input, using default '$SMEARING'"
        fi
        if [[ -z "$DEGAUSS" ]]; then
            DEGAUSS="${DEFAULT_DEGAUSS:-0.02}"
            echo "  note: degauss absent from input, using default $DEGAUSS"
        fi
    fi

    if [[ -z "$ATOMIC_SPECIES_BLOCK" ]]; then
        echo "ERROR: ATOMIC_SPECIES block not found in $INPUT_ABS"
        exit 1
    fi

    # Checked here, in the first step, rather than where it is used. The nscf
    # generator is step 9 of 11, so an unsupported K_POINTS form used to abort
    # only after the relax, scf, band and bands.x steps had already run - a
    # typo costing hours instead of seconds.
    case "$K_POINTS_MODE" in
        automatic)
            if [[ -z "$K_POINTS_LINE" ]]; then
                echo "ERROR: 'K_POINTS automatic' in $INPUT_ABS is not followed by a mesh line."
                exit 1
            fi
            if ! [[ "${K_POINTS_LINE%%!*}" =~ ^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+ ]]; then
                echo "ERROR: cannot read a 'nk1 nk2 nk3' mesh from the K_POINTS line"
                echo "       in $INPUT_ABS: '$K_POINTS_LINE'"
                exit 1
            fi
            ;;
        gamma)
            # A single point cannot be split across pools.
            if (( NPOOL > 1 )); then
                echo "ERROR: this case is gamma-only, but NPOOL is $NPOOL."
                echo "       Pools divide the k-points between rank groups and there is"
                echo "       only one k-point, so all but one pool would idle."
                echo "       FIX: set NPOOL=1 in config.sh for gamma-only cases."
                exit 1
            fi
            ;;
        *)
            echo "ERROR: K_POINTS mode '$K_POINTS_MODE' in $INPUT_ABS is not supported."
            echo "       This pipeline needs a mesh it can scale for the nscf/DOS step,"
            echo "       so the relax input must use 'K_POINTS automatic' (or 'gamma'"
            echo "       for an isolated molecule). An explicit k-point list has no mesh"
            echo "       to scale."
            echo "       The band step is unaffected either way - it always takes its"
            echo "       path from ${CASE_NAME}_band.path."
            exit 1
            ;;
    esac

    CONTROL_EXTRA_BLOCK=$(namelist_passthrough '^[ \t]*&control[ \t]*$'   "$DROP_CONTROL")
    SYSTEM_EXTRA_BLOCK=$(namelist_passthrough  '^[ \t]*&system[ \t]*$'    "$DROP_SYSTEM")
    ELECTRONS_EXTRA_BLOCK=$(namelist_passthrough '^[ \t]*&electrons[ \t]*$' "$DROP_ELECTRONS")

    # Say out loud what is being carried over. These are exactly the settings
    # whose silent loss changes the physics without changing the exit code.
    announce_passthrough CONTROL   "$CONTROL_EXTRA_BLOCK"
    announce_passthrough SYSTEM    "$SYSTEM_EXTRA_BLOCK"
    announce_passthrough ELECTRONS "$ELECTRONS_EXTRA_BLOCK"

    if [[ -n "$EXTRA_CARDS_BLOCK" ]]; then
        echo "  passthrough cards  : $(
            printf '%s\n' "$EXTRA_CARDS_BLOCK" \
                | grep -iE "^[[:space:]]*($CARDS_KEPT)" \
                | sed -E 's/^[[:space:]]*//' \
                | tr '\n' ' ')"
    fi

    cat > "$CACHE_FILE" <<EOF
CACHE_VERSION='${CACHE_VERSION_EXPECTED}'

PREFIX='${PREFIX}'
OUTDIR='${OUTDIR}'
PSEUDO_DIR='${PSEUDO_DIR}'
CALCULATION='${CALCULATION}'

IBRAV='${IBRAV}'
NAT='${NAT}'
NTYP='${NTYP}'
ECUTWFC='${ECUTWFC}'
ECUTRHO='${ECUTRHO}'
OCCUPATIONS='${OCCUPATIONS}'
SMEARING='${SMEARING}'
DEGAUSS='${DEGAUSS}'

CONV_THR='${CONV_THR}'
MIXING_BETA='${MIXING_BETA}'

CELL_DOFREE='${CELL_DOFREE}'

ATOMIC_SPECIES=\$(cat <<'EOF_ATOMIC_SPECIES'
${ATOMIC_SPECIES_BLOCK}
EOF_ATOMIC_SPECIES
)

CONTROL_EXTRA=\$(cat <<'EOF_CONTROL_EXTRA'
${CONTROL_EXTRA_BLOCK}
EOF_CONTROL_EXTRA
)

SYSTEM_EXTRA=\$(cat <<'EOF_SYSTEM_EXTRA'
${SYSTEM_EXTRA_BLOCK}
EOF_SYSTEM_EXTRA
)

ELECTRONS_EXTRA=\$(cat <<'EOF_ELECTRONS_EXTRA'
${ELECTRONS_EXTRA_BLOCK}
EOF_ELECTRONS_EXTRA
)

EXTRA_CARDS=\$(cat <<'EOF_EXTRA_CARDS'
${EXTRA_CARDS_BLOCK}
EOF_EXTRA_CARDS
)

K_POINTS_MODE='${K_POINTS_MODE}'
K_POINTS='${K_POINTS_LINE}'
EOF

    echo "Parser cache saved:"
    echo "$CACHE_FILE"
}

step_dump() {
    require_cache
    printf '%-14s: %s\n' \
        PREFIX "$PREFIX" OUTDIR "$OUTDIR" PSEUDO_DIR "$PSEUDO_DIR" \
        CALCULATION "$CALCULATION" IBRAV "$IBRAV" NAT "$NAT" NTYP "$NTYP" \
        ECUTWFC "$ECUTWFC" ECUTRHO "$ECUTRHO" OCCUPATIONS "$OCCUPATIONS" \
        SMEARING "$SMEARING" DEGAUSS "$DEGAUSS" CONV_THR "$CONV_THR" \
        MIXING_BETA "$MIXING_BETA" CELL_DOFREE "$CELL_DOFREE" \
        K_POINTS_MODE "${K_POINTS_MODE:-}" K_POINTS "$K_POINTS"
    echo "ATOMIC_SPECIES:"
    echo "$ATOMIC_SPECIES"

    local nml
    for nml in CONTROL SYSTEM ELECTRONS; do
        echo "&${nml} passthrough:"
        case "$nml" in
            CONTROL)   printf '%s\n' "${CONTROL_EXTRA:-  (none)}" ;;
            SYSTEM)    printf '%s\n' "${SYSTEM_EXTRA:-  (none)}" ;;
            ELECTRONS) printf '%s\n' "${ELECTRONS_EXTRA:-  (none)}" ;;
        esac
    done

    echo "cards carried over:"
    printf '%s\n' "${EXTRA_CARDS:-  (none)}"
}

#############################
# Step: extract structure
#############################

# The CELL_PARAMETERS block QE prints inside "Begin final coordinates", i.e.
# the cell a vc-relax converged to. Empty output means the block is not there
# (a plain 'relax', or a run that never converged) - that is a valid answer,
# not an error, so the caller decides what to do about it.
#
# QE echoes the cell in whatever unit the input card used, except that it can
# also emit "CELL_PARAMETERS (alat= 6.0234...)" with alat in bohr. pw.x will
# not read that number back, so those vectors are converted to angstrom here
# rather than written out in a form the next step cannot parse.
extract_final_cell() {
    local relax_out="$1"

    awk '
    /^[[:space:]]*Begin final coordinates/ { final = 1 }
    final && /^[[:space:]]*CELL_PARAMETERS/ {
        header = $0
        getline v1; getline v2; getline v3

        if (tolower(header) ~ /alat[[:space:]]*=/) {
            alat = header
            sub(/.*[Aa][Ll][Aa][Tt][[:space:]]*=[[:space:]]*/, "", alat)
            sub(/[^0-9.eEdD+-].*$/, "", alat)
            if (alat + 0 <= 0) {
                print "ERROR: could not read the alat value out of the final" \
                      " CELL_PARAMETERS header: " header > "/dev/stderr"
                exit 1
            }
            scale = (alat + 0) * 0.529177210903   # bohr -> angstrom
            print "CELL_PARAMETERS (angstrom)"
            split(v1, a); printf "  %.10f  %.10f  %.10f\n", a[1]*scale, a[2]*scale, a[3]*scale
            split(v2, b); printf "  %.10f  %.10f  %.10f\n", b[1]*scale, b[2]*scale, b[3]*scale
            split(v3, c); printf "  %.10f  %.10f  %.10f\n", c[1]*scale, c[2]*scale, c[3]*scale
        } else {
            print header; print v1; print v2; print v3
        }
        exit
    }
    ' "$relax_out"
}

step_extract() {
    require_cache

    if [[ ! -f "$RELAX_OUT" ]]; then
        echo "ERROR: $RELAX_OUT not found."
        exit 1
    fi

    local CELL_BLOCK ATOMIC_BLOCK CELL_SOURCE

    # A vc-relax moves the cell, and QE prints the converged one in the
    # "Begin final coordinates" block of the output. Until 2026-07-27 this
    # read CELL_PARAMETERS from the *input* while reading ATOMIC_POSITIONS
    # from the output, so every later step ran on the un-relaxed cell holding
    # the relaxed positions - a structure that was never optimised and never
    # reported as wrong. It also made the pipeline's "relaxed lattice
    # constant" identical to the input value by construction.
    #
    # A plain 'relax' does not move the cell and prints no CELL_PARAMETERS,
    # so falling back to the input block is correct there, not a workaround.
    CELL_BLOCK=$(extract_final_cell "$RELAX_OUT")

    if [[ -n "$CELL_BLOCK" ]]; then
        CELL_SOURCE="relaxed cell from $(basename "$RELAX_OUT")"
    else
        CELL_BLOCK=$(awk '
        /^[[:space:]]*CELL_PARAMETERS[[:space:]]*/ {
            print; getline; print; getline; print; getline; print
            exit
        }
        ' "$RELAX_IN")
        CELL_SOURCE="input cell from $(basename "$RELAX_IN")"

        if [[ "${CALCULATION,,}" == vc-* ]]; then
            echo "WARNING: calculation is '$CALCULATION', which relaxes the cell, but"
            echo "         no final CELL_PARAMETERS was found in $RELAX_OUT."
            echo "         Falling back to the input cell - check that the relax"
            echo "         actually reached 'Begin final coordinates'."
        fi
    fi

    if [[ -z "$CELL_BLOCK" ]]; then
        echo "ERROR: no CELL_PARAMETERS block in $RELAX_OUT or $RELAX_IN."
        echo "       An ibrav /= 0 input has none; this pipeline needs ibrav = 0"
        echo "       with an explicit CELL_PARAMETERS card."
        exit 1
    fi

    ATOMIC_BLOCK=$(awk '
    /^[[:space:]]*ATOMIC_POSITIONS[[:space:]]*/ {
        header=$0; n=0; capture=1; delete block; next
    }
    capture && (NF==0 || /^[[:space:]]*End final coordinates/) {capture=0; next}
    capture {block[++n]=$0}
    END {
        if (header == "") exit 1
        print header
        for (i=1; i<=n; i++) print block[i]
    }
    ' "$RELAX_OUT") || {
        echo "ERROR: ATOMIC_POSITIONS block not found in $RELAX_OUT"
        exit 1
    }

    if [[ -z "$ATOMIC_BLOCK" ]]; then
        echo "ERROR: ATOMIC_POSITIONS block not found in $RELAX_OUT"
        exit 1
    fi

    {
        printf '%s\n\n' "$CELL_BLOCK"
        printf '%s\n' "$ATOMIC_BLOCK"
    } > "$STRUCTURE_FILE"

    echo "Structure extracted: $STRUCTURE_FILE"
    echo "  cell     : $CELL_SOURCE"
    echo "  positions: relaxed positions from $(basename "$RELAX_OUT")"
}

#############################
# Input generation
#############################

# Everything every generated pw.x input shares. The three generators used to
# be three near-identical files differing by ~35 lines each; this is that
# common part, with the K_POINTS block left to the caller because that is
# genuinely different for scf / bands / nscf.
emit_pw_input() {
    local calculation="$1"
    local outfile="$2"

    cat > "$outfile" <<EOF
&CONTROL
    calculation = '$calculation'
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    pseudo_dir = '$PSEUDO_DIR'
EOF

    [[ -n "${CONTROL_EXTRA:-}" ]] && printf '%s\n' "$CONTROL_EXTRA" >> "$outfile"

    cat >> "$outfile" <<EOF
/

&SYSTEM
    ibrav = $IBRAV
    nat = $NAT
    ntyp = $NTYP
    ecutwfc = $ECUTWFC
EOF

    [[ -n "${ECUTRHO:-}" ]]  && echo "    ecutrho = $ECUTRHO"      >> "$outfile"
    echo "    occupations = '$OCCUPATIONS'"                        >> "$outfile"
    [[ -n "${SMEARING:-}" ]] && echo "    smearing = '$SMEARING'"  >> "$outfile"
    [[ -n "${DEGAUSS:-}" ]]  && echo "    degauss = $DEGAUSS"      >> "$outfile"

    # Everything else the input declared in &SYSTEM: nbnd, nspin,
    # starting_magnetization, vdw_corr, edir/emaxpos/eopreg/eamp, ...
    [[ -n "${SYSTEM_EXTRA:-}" ]] && printf '%s\n' "$SYSTEM_EXTRA" >> "$outfile"

    cat >> "$outfile" <<EOF
/

&ELECTRONS
    conv_thr = $CONV_THR
    mixing_beta = $MIXING_BETA
EOF

    [[ -n "${ELECTRONS_EXTRA:-}" ]] && printf '%s\n' "$ELECTRONS_EXTRA" >> "$outfile"

    cat >> "$outfile" <<EOF
/

ATOMIC_SPECIES
$ATOMIC_SPECIES

EOF

    cat "$STRUCTURE_FILE" >> "$outfile"
}

# Cards the input declared that this script does not build itself - HUBBARD
# above all. Appended after the K_POINTS card, which is why every generator
# calls it last rather than emit_pw_input doing it: card order is free in QE,
# but K_POINTS is written by the caller, not by emit_pw_input.
emit_extra_cards() {
    local outfile="$1"
    [[ -z "${EXTRA_CARDS:-}" ]] && return 0
    printf '\n%s\n' "$EXTRA_CARDS" >> "$outfile"
}

# The k-point card for a self-consistent-style step, reproducing whatever
# sampling the input asked for.
emit_kpoints_as_input() {
    local outfile="$1"

    if [[ "${K_POINTS_MODE:-automatic}" == "gamma" ]]; then
        printf '\nK_POINTS gamma\n' >> "$outfile"
    else
        printf '\nK_POINTS automatic\n%s\n' "$K_POINTS" >> "$outfile"
    fi
}

step_gen_scf() {
    require_cache
    require_structure

    emit_pw_input scf "$SCF_IN"
    emit_kpoints_as_input "$SCF_IN"
    emit_extra_cards "$SCF_IN"

    echo "SCF input generated: $SCF_IN"
}

step_gen_band() {
    require_cache
    require_structure

    # The high-symmetry path depends entirely on the Bravais lattice.
    # Gamma-M-K-Gamma is correct only for hexagonal cells, so each case
    # supplies its own path rather than silently inheriting one that would
    # be wrong (and wrong *quietly*) for other symmetries.
    if [[ ! -f "$BAND_PATH_FILE" ]]; then
        echo "ERROR: no band path found for case '$CASE_NAME'."
        echo "Create $BAND_PATH_FILE with the K_POINTS block for this"
        echo "material's own high-symmetry path (use __BAND_POINTS__ where the"
        echo "per-segment point count from config.sh should be substituted)."
        echo "Hexagonal example (graphene/MoS2/WS2-like only):"
        echo "  $ROOT_DIR/template/band.path.hexagonal_example"
        exit 1
    fi

    emit_pw_input bands "$BAND_IN"
    echo "" >> "$BAND_IN"
    sed "s/__BAND_POINTS__/${BAND_POINTS}/g" "$BAND_PATH_FILE" >> "$BAND_IN"
    emit_extra_cards "$BAND_IN"

    echo "Band input generated: $BAND_IN"
}

step_gen_nscf() {
    require_cache
    require_structure

    local KPOINTS_CLEAN KX KY KZ SX SY SZ

    # A gamma-only case has no mesh to densify. Scaling "1 1 1" up would turn
    # an isolated molecule's sampling into a 2x2x2 mesh of a vacuum box, which
    # is just wasted work, so the sampling is reproduced as-is.
    if [[ "${K_POINTS_MODE:-automatic}" == "gamma" ]]; then
        emit_pw_input nscf "$NSCF_IN"
        emit_kpoints_as_input "$NSCF_IN"
        emit_extra_cards "$NSCF_IN"
        echo "NSCF input generated: $NSCF_IN"
        echo "  note: gamma-only case, no k-mesh to scale (NSCF_KPOINT_SCALE ignored)"
        return 0
    fi

    KPOINTS_CLEAN="${K_POINTS%%!*}"
    read -r KX KY KZ SX SY SZ <<< "$KPOINTS_CLEAN"

    if [[ -z "${KX:-}" || -z "${KY:-}" || -z "${KZ:-}" ]]; then
        echo "ERROR: failed to parse K_POINTS from $CACHE_FILE"
        exit 1
    fi

    SX="${SX:-0}"; SY="${SY:-0}"; SZ="${SZ:-0}"

    KX=$((KX * NSCF_KPOINT_SCALE))
    KY=$((KY * NSCF_KPOINT_SCALE))

    # Only a cell the input declares as 2D keeps its single k-point along z.
    if [[ "${CELL_DOFREE,,}" != 2d* ]]; then
        KZ=$((KZ * NSCF_KPOINT_SCALE))
    fi

    emit_pw_input nscf "$NSCF_IN"
    printf '\nK_POINTS automatic\n%s %s %s %s %s %s\n' \
        "$KX" "$KY" "$KZ" "$SX" "$SY" "$SZ" >> "$NSCF_IN"
    emit_extra_cards "$NSCF_IN"

    echo "NSCF input generated: $NSCF_IN"
}

#############################
# Executable steps
#############################

run_pw() {
    local infile="$1"
    local outfile="${infile%.in}.out"

    load_modules

    echo "Running pw.x : $(basename "$infile") -> $(basename "$outfile")"
    (
        cd "$INPUT_DIR"
        $MPI $PW $POOL_FLAG < "$(basename "$infile")" > "$(basename "$outfile")"
    )

    check_done "$outfile" "pw.x ($(basename "$infile"))"
}

step_bandsx() {
    require_cache
    load_modules

    local bands_in="$INPUT_DIR/${CASE_NAME}_bandsx.in"
    local bands_out="$INPUT_DIR/${CASE_NAME}_bandsx.out"

    cat > "$bands_in" <<EOF
&BANDS
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    filband = '${PREFIX}.bands.dat'
/
EOF

    echo "Running bands.x"
    (
        cd "$INPUT_DIR"
        $MPI $BANDS $POOL_FLAG < "$(basename "$bands_in")" > "$(basename "$bands_out")"
    )

    check_done "$bands_out" "bands.x"
}

step_dos() {
    require_cache
    load_modules

    local dos_in="$INPUT_DIR/${CASE_NAME}_dos.in"
    local dos_out="$INPUT_DIR/${CASE_NAME}_dos.out"

    cat > "$dos_in" <<EOF
&DOS
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    fildos = '${PREFIX}.dos'
    DeltaE = $DOS_DELTAE
/
EOF

    echo "Running dos.x"
    (
        cd "$INPUT_DIR"
        $MPI $DOS < "$(basename "$dos_in")" > "$(basename "$dos_out")"
    )

    check_done "$dos_out" "dos.x"
}

#############################
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

    run_step "1/11 PARSER"            step_parser
    require_cache

    run_step "2/11 RELAX"             run_pw "$RELAX_IN"
    run_step "3/11 EXTRACT STRUCTURE" step_extract
    run_step "4/11 GENERATE SCF"      step_gen_scf
    run_step "5/11 SCF"               run_pw "$SCF_IN"
    run_step "6/11 GENERATE BAND"     step_gen_band
    run_step "7/11 BAND"              run_pw "$BAND_IN"
    run_step "8/11 BANDS.X"           step_bandsx
    run_step "9/11 GENERATE NSCF"     step_gen_nscf
    run_step "10/11 NSCF"             run_pw "$NSCF_IN"
    run_step "11/11 DOS"              step_dos

    echo ""
    echo "========================================="
    echo "Workflow Finished Successfully"
    echo "========================================="
}

#############################
# Dispatch
#############################

run_one_step() {
    case "$STEP" in
        all)       step_all ;;
        parser)    step_parser ;;
        dump)      step_dump ;;
        extract)   step_extract ;;
        relax)     require_cache; run_pw "$RELAX_IN" ;;
        gen-scf)   step_gen_scf ;;
        scf)       require_cache; run_pw "$SCF_IN" ;;
        gen-band)  step_gen_band ;;
        band)      require_cache; run_pw "$BAND_IN" ;;
        bandsx)    step_bandsx ;;
        gen-nscf)  step_gen_nscf ;;
        nscf)      require_cache; run_pw "$NSCF_IN" ;;
        dos)       step_dos ;;
        *)
            echo "ERROR: unknown step '$STEP'"
            echo ""
            usage
            exit 1
            ;;
    esac
}

# Reject an unknown step before launching anything, so a typo does not fail
# separately inside every case.
case "$STEP" in
    all|parser|dump|extract|relax|gen-scf|scf|gen-band|band|bandsx|gen-nscf|nscf|dos) ;;
    *)
        echo "ERROR: unknown step '$STEP'"
        echo ""
        usage
        exit 1
        ;;
esac

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
echo "========================================="

if (( FAILED )); then
    echo ""
    echo "At least one case failed; see the step that broke above."
    exit 1
fi

echo ""
echo "All $NCASES cases finished successfully"
