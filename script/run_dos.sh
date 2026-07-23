#!/bin/bash

set -euo pipefail

INPUT="${1:-}"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "./run_dos.sh nscf.in"
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: $INPUT not found."
    exit 1
fi

if [[ "$INPUT" != *_nscf.in ]]; then
    echo "ERROR: input must end with _nscf.in"
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
INPUT_DIR=$(cd "$(dirname "$INPUT")" && pwd)
INPUT_NAME=$(basename "$INPUT")
CASE_NAME="${INPUT_NAME%_nscf.in}"

CACHE_DIR="$INPUT_DIR/cache"

if [[ ! -f "$CACHE_DIR/parser.cache" ]]; then
    echo "ERROR: parser.cache not found."
    exit 1
fi

source "$CACHE_DIR/parser.cache"
source "$ROOT_DIR/config.sh"

DOS_INPUT="$INPUT_DIR/${CASE_NAME}_dos.in"
DOS_OUTPUT="$INPUT_DIR/${CASE_NAME}_dos.out"

cat > "$DOS_INPUT" <<EOF
&DOS
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    fildos = '${PREFIX}.dos'
    DeltaE = $DOS_DELTAE
/
EOF

echo ""
echo "=================================="
echo "Running dos.x"
echo "Input  : $(basename "$DOS_INPUT")"
echo "Output : $(basename "$DOS_OUTPUT")"
echo "=================================="

(
    cd "$INPUT_DIR"
    $MPI $DOS < "$(basename "$DOS_INPUT")" > "$(basename "$DOS_OUTPUT")"
)

"$SCRIPT_DIR/check_job.sh" "$DOS_OUTPUT"

echo "DOS finished successfully."
