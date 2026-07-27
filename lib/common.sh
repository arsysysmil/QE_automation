#!/bin/bash
# Shared helpers: environment, per-case state, diagnostics.
#
# Sourced by qe.sh. Not executable on its own.

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

# Post-mortem on a case that has already run: which stages finished, and for
# those that did not, why.
#
# v1 had this as a standalone script/check_job.sh you could point at any .out
# file after the fact. Merging into one file turned check_done/diagnose_failure
# into internals only reachable mid-run, and that was a real loss - the value
# of a diagnosis is largely in reading it later. This restores it, over the
# whole case rather than one file at a time.
step_check() {
    local out label found=0 failed=0

    for out in "$RELAX_OUT" "$SCF_OUT" "$BAND_OUT" \
               "$INPUT_DIR/${CASE_NAME}_bandsx.out" \
               "$NSCF_OUT" \
               "$INPUT_DIR/${CASE_NAME}_dos.out"; do
        [[ -f "$out" ]] || continue

        found=$(( found + 1 ))
        label="$(basename "$out")"

        if grep -q "JOB DONE." "$out"; then
            printf 'SUCCESS : %s\n' "$label"
        else
            printf 'FAILED  : %s\n' "$label"
            diagnose_failure "$out"
            failed=$(( failed + 1 ))
        fi
    done

    if (( found == 0 )); then
        echo "No output files for case '$CASE_NAME' in $INPUT_DIR."
        echo "Nothing has run yet, or it ran somewhere else."
        return 0
    fi

    echo ""
    echo "$found output(s) checked, $failed failed."
    (( failed == 0 ))
}
