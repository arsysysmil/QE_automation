#!/bin/bash
#SBATCH --job-name=QE_workflow
#SBATCH --partition=short
#SBATCH --nodes=1
#SBATCH --ntasks=64
#SBATCH --cpus-per-task=1
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.out

set -euo pipefail

get_script_dir() {
    local cmd=""

    # SLURM_SUBMIT_DIR is always the real directory `sbatch` was invoked
    # from. Prefer it: scontrol's Command= field can instead point at a
    # spooled copy of this script (e.g. /var/spool/slurm/d/job.../slurm_script)
    # whose sibling script/ folder does not exist, which breaks HELPER_DIR.
    if [[ -n "${SLURM_SUBMIT_DIR:-}" && -d "${SLURM_SUBMIT_DIR:-}" ]]; then
        readlink -f "$SLURM_SUBMIT_DIR"
        return 0
    fi

    if [[ -n "${SLURM_JOB_ID:-}" ]] && command -v scontrol >/dev/null 2>&1; then
        cmd="$(scontrol show job "$SLURM_JOB_ID" 2>/dev/null | tr ' ' '\n' | awk -F= '/^Command=/{print $2; exit}')"
        if [[ -n "${cmd:-}" && -f "$cmd" ]]; then
            dirname "$(readlink -f "$cmd")"
            return 0
        fi
    fi

    pwd -P
}

SCRIPT_DIR="$(get_script_dir)"
HELPER_DIR="$SCRIPT_DIR/script"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "sbatch run.sh /path/to/case_relax.in"
    exit 1
fi

if [[ ! -f "$1" ]]; then
    echo "ERROR: input file not found: $1 (resolved from cwd: $(pwd -P))"
    exit 1
fi

INPUT_ABS="$(readlink -f "$1")"

INPUT_DIR="$(dirname "$INPUT_ABS")"
INPUT_NAME="$(basename "$INPUT_ABS")"

if [[ "$INPUT_NAME" != *_relax.in ]]; then
    echo "ERROR: input must end with _relax.in"
    exit 1
fi

CASE_NAME="${INPUT_NAME%_relax.in}"

for f in parser.sh run_pw.sh extract_structure.sh generate_scf.sh generate_band.sh generate_nscf.sh run_bands.sh run_dos.sh; do
    if [[ ! -f "$HELPER_DIR/$f" ]]; then
        echo "ERROR: missing helper script: $HELPER_DIR/$f"
        exit 1
    fi
done

module purge
module load intel/2024.0
module load impi/2021.11.0
module load mkl
module load materials/qe/7.2-impi

export OMP_NUM_THREADS=1
ulimit -l unlimited

mkdir -p "$INPUT_DIR/work" "$INPUT_DIR/logs"
cd "$INPUT_DIR"

# logs/pipeline.out is a single, always-up-to-date place to check progress:
# a symlink to this run's own log (which otherwise only lives in
# QE_workflow/, not next to the case), enriched below with a per-step
# duration instead of duplicating each step's already-existing .out file.
LOGS_DIR="$INPUT_DIR/logs"
if [[ -n "${SLURM_JOB_ID:-}" ]]; then
    ln -sf "$SCRIPT_DIR/slurm-${SLURM_JOB_ID}.out" "$LOGS_DIR/pipeline.out"
fi

echo "========================================="
echo "Quantum ESPRESSO Workflow Started"
echo "Script dir : $SCRIPT_DIR"
echo "Input      : $INPUT_ABS"
echo "Case       : $CASE_NAME"
echo "Work dir   : $INPUT_DIR"
echo "Logs       : $LOGS_DIR"
echo "========================================="

format_duration() {
    local secs="$1"
    printf '%dh%dm%ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

run_and_check() {
    local label="$1"
    local cmd="$2"
    local outfile="$3"
    local start_ts end_ts

    echo ""
    echo "[$label] $cmd"
    echo "  started : $(date '+%Y-%m-%d %H:%M:%S')"
    start_ts=$(date +%s)

    # Plain non-login shell: a login shell (-l) re-sources /etc/profile,
    # which auto-loads this cluster's default OpenHPC OpenMPI module on
    # top of the intel/impi modules loaded above, silently swapping out
    # `mpirun` for one that can't launch an Intel-MPI-linked pw.x
    # (PMI mismatch -> PMPI_Init crash). Plain bash -c inherits this
    # script's already-correct module environment untouched.
    bash -c "$cmd"

    end_ts=$(date +%s)
    echo "  finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  duration: $(format_duration $((end_ts - start_ts)))"

    if [[ -n "$outfile" ]]; then
        if [[ ! -f "$outfile" ]]; then
            echo "ERROR: output file not found: $outfile"
            exit 1
        fi
        if ! grep -q "JOB DONE." "$outfile"; then
            echo "ERROR: $label did not finish cleanly."
            echo "Last lines of $outfile:"
            tail -n 40 "$outfile" || true
            exit 1
        fi
    fi
}

RELAX_OUT="$INPUT_DIR/${CASE_NAME}_relax.out"
SCF_IN="$INPUT_DIR/${CASE_NAME}_scf.in"
SCF_OUT="$INPUT_DIR/${CASE_NAME}_scf.out"
BAND_IN="$INPUT_DIR/${CASE_NAME}_band.in"
BAND_OUT="$INPUT_DIR/${CASE_NAME}_band.out"
NSCF_IN="$INPUT_DIR/${CASE_NAME}_nscf.in"
NSCF_OUT="$INPUT_DIR/${CASE_NAME}_nscf.out"

run_and_check "1/11 PARSER" \
    "bash '$HELPER_DIR/parser.sh' '$INPUT_ABS'" \
    ""

run_and_check "2/11 RELAX" \
    "bash '$HELPER_DIR/run_pw.sh' '$INPUT_ABS'" \
    "$RELAX_OUT"

run_and_check "3/11 EXTRACT STRUCTURE" \
    "bash '$HELPER_DIR/extract_structure.sh' '$INPUT_ABS' '$RELAX_OUT'" \
    ""

run_and_check "4/11 GENERATE SCF" \
    "bash '$HELPER_DIR/generate_scf.sh' '$INPUT_ABS'" \
    ""

if [[ ! -f "$SCF_IN" ]]; then
    echo "ERROR: SCF input not created: $SCF_IN"
    exit 1
fi

run_and_check "5/11 SCF" \
    "bash '$HELPER_DIR/run_pw.sh' '$SCF_IN'" \
    "$SCF_OUT"

run_and_check "6/11 GENERATE BAND" \
    "bash '$HELPER_DIR/generate_band.sh' '$INPUT_ABS'" \
    ""

if [[ ! -f "$BAND_IN" ]]; then
    echo "ERROR: BAND input not created: $BAND_IN"
    exit 1
fi

run_and_check "7/11 BAND" \
    "bash '$HELPER_DIR/run_pw.sh' '$BAND_IN'" \
    "$BAND_OUT"

run_and_check "8/11 BANDS.X" \
    "bash '$HELPER_DIR/run_bands.sh' '$BAND_IN'" \
    ""

run_and_check "9/11 GENERATE NSCF" \
    "bash '$HELPER_DIR/generate_nscf.sh' '$INPUT_ABS'" \
    ""

if [[ ! -f "$NSCF_IN" ]]; then
    echo "ERROR: NSCF input not created: $NSCF_IN"
    exit 1
fi

run_and_check "10/11 NSCF" \
    "bash '$HELPER_DIR/run_pw.sh' '$NSCF_IN'" \
    "$NSCF_OUT"

run_and_check "11/11 DOS" \
    "bash '$HELPER_DIR/run_dos.sh' '$NSCF_IN'" \
    ""

echo ""
echo "========================================="
echo "Workflow Finished Successfully"
echo "========================================="
