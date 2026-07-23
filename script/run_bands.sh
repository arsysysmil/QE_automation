#!/bin/bash

set -euo pipefail

INPUT="${1:-}"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "./run_bands.sh band.in"
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: $INPUT not found."
    exit 1
fi

if [[ "$INPUT" != *_band.in ]]; then
    echo "ERROR: input must end with _band.in"
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
INPUT_DIR=$(cd "$(dirname "$INPUT")" && pwd)
INPUT_NAME=$(basename "$INPUT")
CASE_NAME="${INPUT_NAME%_band.in}"

CACHE_DIR="$INPUT_DIR/cache"

if [[ ! -f "$CACHE_DIR/parser.cache" ]]; then
    echo "ERROR: parser.cache not found."
    exit 1
fi

source "$CACHE_DIR/parser.cache"
source "$ROOT_DIR/config.sh"

BANDS_INPUT="$INPUT_DIR/${CASE_NAME}_bandsx.in"
BANDS_OUTPUT="$INPUT_DIR/${CASE_NAME}_bandsx.out"

cat > "$BANDS_INPUT" <<EOF
&BANDS
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    filband = '${PREFIX}.bands.dat'
/
EOF

echo ""
echo "=================================="
echo "Running bands.x"
echo "Input  : $(basename "$BANDS_INPUT")"
echo "Output : $(basename "$BANDS_OUTPUT")"
echo "=================================="

(
    cd "$INPUT_DIR"
    $MPI $BANDS < "$(basename "$BANDS_INPUT")" > "$(basename "$BANDS_OUTPUT")"
)

"$SCRIPT_DIR/check_job.sh" "$BANDS_OUTPUT"

echo "bands.x finished successfully."
