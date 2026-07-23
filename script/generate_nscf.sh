#!/bin/bash

set -euo pipefail

INPUT="${1:-}"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "./generate_nscf.sh relax.in"
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

source "$CACHE_DIR/parser.cache"
source "$ROOT_DIR/config.sh"

INPUT_NAME=$(basename "$INPUT")
CASE_NAME="${INPUT_NAME%_relax.in}"
OUTPUT="$INPUT_DIR/${CASE_NAME}_nscf.in"

KPOINTS_CLEAN="${K_POINTS%%!*}"
read -r KX KY KZ SX SY SZ <<< "$KPOINTS_CLEAN"

if [[ -z "${KX:-}" || -z "${KY:-}" || -z "${KZ:-}" ]]; then
    echo "ERROR: failed to parse K_POINTS from parser.cache"
    exit 1
fi

SX="${SX:-0}"
SY="${SY:-0}"
SZ="${SZ:-0}"

KX=$((KX * NSCF_KPOINT_SCALE))
KY=$((KY * NSCF_KPOINT_SCALE))

cat > "$OUTPUT" <<EOF
&CONTROL
    calculation = 'nscf'
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
$KX $KY $KZ $SX $SY $SZ
EOF

echo ""
echo "=================================="
echo "NSCF input generated:"
echo "$OUTPUT"
echo "=================================="
