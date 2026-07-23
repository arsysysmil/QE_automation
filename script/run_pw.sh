#!/bin/bash

set -euo pipefail

INPUT="${1:-}"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "./run_pw.sh input.in"
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: $INPUT not found."
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
source "$ROOT_DIR/config.sh"

INPUT_DIR=$(cd "$(dirname "$INPUT")" && pwd)
INPUT_NAME=$(basename "$INPUT")
OUTPUT_NAME="${INPUT_NAME%.in}.out"
OUTPUT="$INPUT_DIR/$OUTPUT_NAME"

echo ""
echo "===================================="
echo "Running PWscf"
echo "Input  : $INPUT_NAME"
echo "Output : $OUTPUT_NAME"
echo "===================================="

(
    cd "$INPUT_DIR"
    $MPI $PW < "$INPUT_NAME" > "$OUTPUT_NAME"
)

if [[ ! -f "$OUTPUT" ]]; then
    echo "ERROR: output file was not created."
    exit 1
fi

"$SCRIPT_DIR/check_job.sh" "$OUTPUT"

echo "PWscf finished successfully."
