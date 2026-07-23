#!/bin/bash

set -euo pipefail

INPUT="${1:-}"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "./generate_scf.sh relax.in"
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

source "$CACHE_DIR/parser.cache"

INPUT_NAME=$(basename "$INPUT")
CASE_NAME="${INPUT_NAME%_relax.in}"
OUTPUT="$INPUT_DIR/${CASE_NAME}_scf.in"

cat > "$OUTPUT" <<EOF
&CONTROL
    calculation = 'scf'
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

cat >> "$OUTPUT" <<EOF

K_POINTS automatic
$K_POINTS
EOF

echo ""
echo "=================================="
echo "SCF input generated:"
echo "$OUTPUT"
echo "=================================="
