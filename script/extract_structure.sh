#!/bin/bash

set -euo pipefail

RELAX_IN="${1:-}"
RELAX_OUT="${2:-}"

if [[ $# -ne 2 ]]; then
    echo "Usage:"
    echo "./extract_structure.sh relax.in relax.out"
    exit 1
fi

if [[ ! -f "$RELAX_IN" ]]; then
    echo "ERROR: $RELAX_IN not found."
    exit 1
fi

if [[ ! -f "$RELAX_OUT" ]]; then
    echo "ERROR: $RELAX_OUT not found."
    exit 1
fi

INPUT_DIR=$(cd "$(dirname "$RELAX_IN")" && pwd)
CACHE_DIR="$INPUT_DIR/cache"
mkdir -p "$CACHE_DIR"

STRUCTURE_FILE="$CACHE_DIR/structure.in"

CELL_BLOCK=$(awk '
/^[[:space:]]*CELL_PARAMETERS[[:space:]]*/ {
    print
    getline; print
    getline; print
    getline; print
    exit
}
' "$RELAX_IN")

if [[ -z "$CELL_BLOCK" ]]; then
    echo "ERROR: CELL_PARAMETERS block not found in $RELAX_IN"
    exit 1
fi

ATOMIC_BLOCK=$(awk '
/^[[:space:]]*ATOMIC_POSITIONS[[:space:]]*/ {
    header=$0
    n=0
    capture=1
    delete block
    next
}
capture && (NF==0 || /^[[:space:]]*End final coordinates/) {capture=0; next}
capture {block[++n]=$0}
END {
    if (header == "") exit 1
    print header
    for (i=1; i<=n; i++) print block[i]
}
' "$RELAX_OUT") || {
    echo "ERROR: ATOMIC_POSITIONS block not found in $RELAX_OUT"
    exit 1
}

if [[ -z "$ATOMIC_BLOCK" ]]; then
    echo "ERROR: ATOMIC_POSITIONS block not found in $RELAX_OUT"
    exit 1
fi

{
    printf '%s\n\n' "$CELL_BLOCK"
    printf '%s\n' "$ATOMIC_BLOCK"
} > "$STRUCTURE_FILE"

echo ""
echo "======================================"
echo "Structure extracted successfully"
echo "Output : $STRUCTURE_FILE"
echo "======================================"
