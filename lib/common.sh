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

    # Per case, not per directory. A folder holding gra1, gra2 and gra3 must
    # give each of them its own cache, or `qe.sh parser <folder>` followed
    # later by `qe.sh gen-scf <folder>` would generate all three scf inputs
    # from whichever case parsed last.
    STRUCTURE_FILE="$CACHE_DIR/${CASE_NAME}.structure.in"
    CACHE_FILE="$CACHE_DIR/${CASE_NAME}.parser.cache"

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

#############################
# Where a run got to
#############################
#
# A job killed by the scheduler - walltime, scancel, OOM, a node dropping out -
# gets SIGKILL, which no trap can catch and which leaves the output stream
# ending mid-sentence. The last line of slurm-<id>.out can be hours of pw.x
# output away from the step header that would name the stage, and for a
# multi-case run the summary never prints at all.
#
# So the state is written to disk *before* each step starts, not after it
# finishes. A step whose RUNNING line has no OK/FAILED line after it is a step
# that was interrupted, and that is true no matter how violently the process
# died. status_report() below turns that into a sentence.
#
# Cheap enough to do unconditionally: one short append per step, against steps
# that take minutes to hours.

STATUS_FILE=""

# Appends rather than truncates, so re-running one step to redo a figure does
# not erase the record of the twelve-step run that produced the data. Each run
# opens with a '# run' line and status_report() reads only the last block.
status_begin() {
    local total="$1"

    STATUS_FILE="$LOGS_DIR/${CASE_NAME}.status.tsv"

    {
        printf '# run\n'
        printf '# case\t%s\n'    "$CASE_NAME"
        printf '# job\t%s\n'     "${SLURM_JOB_ID:-manual}"
        printf '# started\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# steps\t%s\n'   "$total"
    } >> "$STATUS_FILE"
}

# index total name RUNNING|OK|FAILED|INTERRUPTED [duration]
status_mark() {
    [[ -n "$STATUS_FILE" ]] || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$(date '+%Y-%m-%d %H:%M:%S')" "${5:-}" \
        >> "$STATUS_FILE"
}

# The step a case is sitting on, as "5/12 scf", or nothing if there is no
# status file. Used by the multi-case summary, which runs in the parent shell
# where the failing case's LOGS_DIR is out of scope.
status_last_step() {
    local input_abs="$1"
    local f
    local case_name
    case_name="$(basename "$input_abs")"; case_name="${case_name%_relax.in}"
    f="$(dirname "$input_abs")/logs/${case_name}.status.tsv"

    [[ -f "$f" ]] || return 0
    grep -v '^#' "$f" | tail -1 | awk -F'\t' 'NF { printf "%s/%s %s", $1, $2, $3 }'
}

# The whole history of the last run of this case: every step, its outcome, and
# an explicit verdict when the last step never finished.
status_report() {
    local f="$LOGS_DIR/${CASE_NAME}.status.tsv"

    [[ -f "$f" ]] || return 0

    # Only the most recent run: everything after the last '# run' line.
    local block
    block="$(awk '/^# run$/ { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }' "$f")"
    [[ -n "$block" ]] || return 0

    local case_name job started total
    case_name="$(awk -F'\t' '$1=="# case"    {print $2}' <<<"$block")"
    job="$(awk      -F'\t' '$1=="# job"     {print $2}' <<<"$block")"
    started="$(awk  -F'\t' '$1=="# started" {print $2}' <<<"$block")"
    total="$(awk    -F'\t' '$1=="# steps"   {print $2}' <<<"$block")"

    echo "Last run of '$case_name' (job ${job:-?}, started ${started:-?}):"

    # One line per step. A RUNNING line followed by an OK/FAILED line for the
    # same step is just the pair around a step that ran, so only the outcome is
    # shown; a RUNNING line with nothing after it is the interesting case.
    awk -F'\t' '
        /^#/ { next }
        NF < 4 { next }
        {
            idx = $1; tot = $2; name = $3; state = $4; when = $5; dur = $6
            if (state == "RUNNING") {
                pending_idx = idx; pending_tot = tot
                pending_name = name; pending_when = when
                next
            }
            printf "  %2s/%-2s  %-9s %-8s %s\n", idx, tot, name, state, dur
            pending_idx = ""
        }
        END {
            if (pending_idx != "")
                printf "  %2s/%-2s  %-9s %-8s started %s\n",
                       pending_idx, pending_tot, pending_name, "RUNNING", pending_when
        }
    ' <<<"$block"

    local last state
    last="$(grep -v '^#' <<<"$block" | tail -1)"
    state="$(awk -F'\t' '{print $4}' <<<"$last")"

    case "$state" in
        RUNNING)
            local idx name when
            idx="$(awk  -F'\t' '{print $1}' <<<"$last")"
            name="$(awk -F'\t' '{print $3}' <<<"$last")"
            when="$(awk -F'\t' '{print $5}' <<<"$last")"
            echo ""
            echo "INTERRUPTED: step $idx/$total ($name) started at $when and never"
            echo "  finished. The process was killed while it was running - walltime,"
            echo "  scancel, out of memory, or a node failure - so nothing after it ran."
            if [[ -n "$job" && "$job" != "manual" ]]; then
                echo "  What killed it:"
                echo "    sacct -j $job --format=JobID,State,ExitCode,Elapsed,Timelimit,MaxRSS"
            fi
            echo "  To resume, re-run the steps from $name onwards; the finished ones"
            echo "  above left their outputs in place."
            ;;
        FAILED)
            local idx name
            idx="$(awk  -F'\t' '{print $1}' <<<"$last")"
            name="$(awk -F'\t' '{print $3}' <<<"$last")"
            echo ""
            echo "STOPPED: step $idx/$total ($name) failed. The reason was printed when"
            echo "  it happened; the per-output diagnosis below repeats what can still"
            echo "  be read off the files."
            ;;
        OK)
            local idx
            idx="$(awk -F'\t' '{print $1}' <<<"$last")"
            if [[ "$idx" == "$total" ]]; then
                echo ""
                echo "COMPLETE: all $total steps finished."
            else
                echo ""
                echo "PARTIAL: stopped cleanly after step $idx/$total (a single-step run,"
                echo "  or a pipeline that was not asked to go further)."
            fi
            ;;
    esac
    echo ""
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

#############################
# Nothing derived may be older than what it was derived from
#############################
#
# Steps hand state to each other through files: the input is parsed into
# cache/<case>.parser.cache, the relax output into cache/<case>.structure.in,
# and those two (plus <case>_band.path) into the generated scf/band/nscf
# inputs. Every one of those is a snapshot of something that can change under
# it: edit the input after generating <case>_scf.in and the generated file
# still carries the old ecutwfc, with no warning and exit 0.
#
# The rule is one line: a derived file must not be OLDER than its sources.
# Which also means hand-editing a generated input is still respected - your
# edit is the newest thing there, so nothing complains about it.
#
# mtime, not a checksum: it needs no extra state, and "strictly newer" means
# files written in the same second do not trip it, which keeps a fast pipeline
# quiet.

# The sources that are newer than the derived file, by name. Empty if it is
# up to date, or if it does not exist yet (that is a different problem, and
# the caller reports it).
newer_sources() {
    local derived="$1"; shift
    local src

    [[ -f "$derived" ]] || return 0

    for src in "$@"; do
        [[ -f "$src" ]] || continue
        [[ "$src" -nt "$derived" ]] && printf '%s ' "$(basename "$src")"
    done

    return 0
}

# For the generated pw.x inputs. Refuses rather than regenerating: these sit
# next to the input file and are plausibly hand-tuned, so silently rewriting
# one would throw away work. The fix is one command and it is named.
assert_generated_fresh() {
    local generated="$1" regen_step="$2"; shift 2
    local stale

    stale="$(newer_sources "$generated" "$@")"
    [[ -n "$stale" ]] || return 0

    echo "ERROR: $(basename "$generated") is older than: $stale"
    echo "       It was generated from an earlier version of those, so running it"
    echo "       now would compute something other than what they currently say -"
    echo "       with no error anywhere, which is the whole reason this is checked."
    echo "       FIX: bash qe.sh $regen_step $INPUT_NAME"
    echo "       (if you edited $(basename "$generated") by hand on purpose, it is"
    echo "        already newer than its sources and this would not have fired)"
    exit 1
}

require_cache() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        echo "ERROR: $CACHE_FILE not found - run the 'parser' step first."
        exit 1
    fi

    # Regenerated rather than refused: the cache lives under cache/, is nobody's
    # hand-written file, and re-reading the input is the cheapest step there is.
    if [[ "$INPUT_ABS" -nt "$CACHE_FILE" ]]; then
        echo "  note: $INPUT_NAME has changed since $(basename "$CACHE_FILE") was"
        echo "        written - re-parsing it, so what you edited is what runs"
        step_parser
    fi

    source "$CACHE_FILE"

    # A cache whose layout does not match this qe.sh is rebuilt rather than
    # sourced: a missing field would leave the passthrough quietly empty.
    if [[ "${CACHE_VERSION:-0}" != "$CACHE_VERSION_EXPECTED" ]]; then
        echo "  note: $CACHE_FILE is version ${CACHE_VERSION:-0}," \
             "expected ${CACHE_VERSION_EXPECTED} - refreshing it"
        step_parser
        source "$CACHE_FILE"
    fi
}

require_structure() {
    if [[ ! -f "$STRUCTURE_FILE" ]]; then
        echo "ERROR: $STRUCTURE_FILE not found - run the 'extract' step first."
        exit 1
    fi

    # Same reasoning as the cache: cache/<case>.structure.in is internal state,
    # and re-reading the relax output costs nothing. A relax that was re-run
    # leaves a newer .out, and the geometry every later step uses has to come
    # from it rather than from the run before.
    if [[ "$RELAX_OUT" -nt "$STRUCTURE_FILE" ]]; then
        echo "  note: $(basename "$RELAX_OUT") is newer than"
        echo "        $(basename "$STRUCTURE_FILE") - re-extracting the geometry"
        step_extract
    fi
}

#############################

# Post-mortem on a case that has already run: which stages finished, and for
# those that did not, why. Runs over the whole case at any time, including
# hours after the job ended.
step_check() {
    local out label found=0 failed=0

    # CALCULATION comes from the cache, and check() deliberately does not
    # require one - it has to work on a folder whose run died before the
    # parser, and on output copied down from somewhere else. Read it from the
    # input when the cache has not been sourced.
    local calc="${CALCULATION:-}"
    [[ -n "$calc" ]] || calc="$(get_param calculation)"

    # Where the run got to, before the per-file scan. A file-by-file report
    # answers "which outputs are good"; it cannot answer "why did it stop
    # after four of them", because a step that was killed before writing
    # anything leaves no file to scan. That is what the status file is for.
    status_report

    for out in "$RELAX_OUT" "$SCF_OUT" "$BAND_OUT" \
               "$INPUT_DIR/${CASE_NAME}_bandsx.out" \
               "$INPUT_DIR/${CASE_NAME}_bandsx_up.out" \
               "$INPUT_DIR/${CASE_NAME}_bandsx_dn.out" \
               "$NSCF_OUT" \
               "$INPUT_DIR/${CASE_NAME}_dos.out"; do
        [[ -f "$out" ]] || continue

        found=$(( found + 1 ))
        label="$(basename "$out")"

        if grep -q "JOB DONE." "$out"; then
            # JOB DONE. is not the whole story for a relax: pw.x prints it for
            # a BFGS run that ran out of ionic steps too, and the geometry in
            # that file is the last step taken rather than a minimum. So the
            # headline for the relax output is the convergence verdict, not the
            # exit status - "SUCCESS" above "NOT CONVERGED" would be the same
            # mixed message this check exists to remove.
            #
            # Reported rather than asserted: `check` is a post-mortem, and it
            # should describe what is on disk instead of refusing to.
            if [[ "$out" == "$RELAX_OUT" && "${calc,,}" == *relax* ]]; then
                relax_convergence_scan "$out"

                if [[ -n "$RELAX_CONVERGED_LINE" ]]; then
                    printf 'SUCCESS : %s\n' "$label"
                    printf '          %s\n' "$RELAX_CONVERGED_LINE"
                    relax_final_force_note "$calc" | sed 's/^  /          /'
                else
                    printf 'NOT DONE: %s\n' "$label"
                    printf '          pw.x finished cleanly (JOB DONE) but the geometry did not converge.\n'
                    if (( RELAX_MAXSTEPS )); then
                        printf '          BFGS reached the maximum number of ionic steps.\n'
                    else
                        printf '          No bfgs result in this output at all.\n'
                    fi
                    printf '          What is in this file is the last step taken, not a minimum -\n'
                    printf '          anything computed from it describes a structure that is not one.\n'
                    [[ -n "$RELAX_MAX_FORCE" ]] && \
                        printf '          largest force component %s Ry/au, threshold %s\n' \
                               "$RELAX_MAX_FORCE" "${RELAX_FORCE_THRESHOLD:-?}"
                    failed=$(( failed + 1 ))
                fi
            else
                printf 'SUCCESS : %s\n' "$label"
            fi
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
