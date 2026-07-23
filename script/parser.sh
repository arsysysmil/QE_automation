#!/bin/bash

set -euo pipefail

INPUT="${1:-}"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "./parser.sh relax.in"
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: Input file $INPUT not found."
    exit 1
fi

INPUT_DIR=$(cd "$(dirname "$INPUT")" && pwd)
CACHE_DIR="$INPUT_DIR/cache"
mkdir -p "$CACHE_DIR"

get_param() {
    local key="$1"
    local value

    value=$(
        grep -iE "^[[:space:]]*${key}[[:space:]]*=" "$INPUT" \
        | head -1 \
        | sed -E "s/^[^=]*=[[:space:]]*//; s/[',]//g; s/[[:space:]]+$//" \
        || true
    )

    printf '%s' "$value"
}

PREFIX=$(get_param prefix)
[[ -z "$PREFIX" ]] && PREFIX="pwscf"

OUTDIR=$(get_param outdir)
[[ -z "$OUTDIR" ]] && OUTDIR="./work"

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

CONV_THR=$(get_param conv_thr)
MIXING_BETA=$(get_param mixing_beta)

ATOMIC_SPECIES_BLOCK=$(awk '
/^[[:space:]]*ATOMIC_SPECIES[[:space:]]*$/ {flag=1; next}
flag && /^[[:space:]]*$/ {exit}
flag {print}
' "$INPUT")

K_POINTS_LINE=$(awk '
/^[[:space:]]*K_POINTS[[:space:]]*/ {
    getline
    sub(/!.*/, "", $0)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
    print
    exit
}
' "$INPUT")

if [[ -z "$PSEUDO_DIR" ]]; then
    echo "ERROR: pseudo_dir not found in $INPUT"
    exit 1
fi

for var in NAT NTYP ECUTWFC OCCUPATIONS SMEARING DEGAUSS CONV_THR MIXING_BETA; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: $var not found in $INPUT"
        exit 1
    fi
done

if [[ -z "$ATOMIC_SPECIES_BLOCK" ]]; then
    echo "ERROR: ATOMIC_SPECIES block not found in $INPUT"
    exit 1
fi

if [[ -z "$K_POINTS_LINE" ]]; then
    echo "ERROR: K_POINTS block not found in $INPUT"
    exit 1
fi

CACHE_FILE="$CACHE_DIR/parser.cache"

cat > "$CACHE_FILE" <<EOF
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

ATOMIC_SPECIES=\$(cat <<'EOF_ATOMIC_SPECIES'
${ATOMIC_SPECIES_BLOCK}
EOF_ATOMIC_SPECIES
)

K_POINTS='${K_POINTS_LINE}'
EOF

echo "Parser cache saved:"
echo "$CACHE_FILE"
