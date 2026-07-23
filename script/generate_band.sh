#!/bin/bash

set -euo pipefail

INPUT="${1:-}"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "./generate_band.sh relax.in"
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: $INPUT not found."
    exit 1
fi

if [[ "$INPUT" != *_relax.in ]]; then
    echo "ERROR: input must end with _relax.in"
    exit 1
fi

INPUT_DIR=$(cd "$(dirname "$INPUT")" && pwd)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
CACHE_DIR="$INPUT_DIR/cache"
STRUCTURE_FILE="$CACHE_DIR/structure.in"

if [[ ! -f "$CACHE_DIR/parser.cache" ]]; then
    echo "ERROR: parser.cache not found."
    exit 1
fi

if [[ ! -f "$STRUCTURE_FILE" ]]; then
    echo "ERROR: structure.in not found."
    exit 1
fi

if [[ ! -f "$ROOT_DIR/template/band.path" ]]; then
    echo "ERROR: band.path not found in $ROOT_DIR/template/"
    exit 1
fi

source "$CACHE_DIR/parser.cache"
source "$ROOT_DIR/config.sh"

INPUT_NAME=$(basename "$INPUT")
CASE_NAME="${INPUT_NAME%_relax.in}"
OUTPUT="$INPUT_DIR/${CASE_NAME}_band.in"

cat > "$OUTPUT" <<EOF
&CONTROL
    calculation = 'bands'
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    pseudo_dir = '$PSEUDO_DIR'
/

&SYSTEM
    ibrav = $IBRAV
    nat = $NAT
    ntyp = $NTYP
    ecutwfc = $ECUTWFC
EOF

if [[ -n "${ECUTRHO:-}" ]]; then
    echo "    ecutrho = $ECUTRHO" >> "$OUTPUT"
fi

cat >> "$OUTPUT" <<EOF
    occupations = '$OCCUPATIONS'
    smearing = '$SMEARING'
    degauss = $DEGAUSS
/

&ELECTRONS
    conv_thr = $CONV_THR
    mixing_beta = $MIXING_BETA
/

ATOMIC_SPECIES
$ATOMIC_SPECIES

EOF

cat "$STRUCTURE_FILE" >> "$OUTPUT"

echo "" >> "$OUTPUT"
sed "s/__BAND_POINTS__/${BAND_POINTS}/g" "$ROOT_DIR/template/band.path" >> "$OUTPUT"

echo ""
echo "=================================="
echo "Band input generated:"
echo "$OUTPUT"
echo "=================================="
