#!/bin/bash

source parser.sh "$1"

echo "======================"

echo "PREFIX       : $PREFIX"

echo "OUTDIR       : $OUTDIR"

echo "PSEUDO_DIR   : $PSEUDO_DIR"

echo "IBRAV        : $IBRAV"

echo "NAT          : $NAT"

echo "NTYP         : $NTYP"

echo "ECUTWFC      : $ECUTWFC"

echo "ECUTRHO      : $ECUTRHO"

echo "CALCULATION  : $CALCULATION"

echo "OCCUPATIONS  : $OCCUPATIONS"

echo "SMEARING     : $SMEARING"

echo "DEGAUSS      : $DEGAUSS"

echo "CONV_THR     : $CONV_THR"

echo "MIXING_BETA  : $MIXING_BETA"

echo ""

echo "===== ATOMIC SPECIES ====="

echo "$ATOMIC_SPECIES_BLOCK"

echo ""

echo "===== K_POINTS LINE ====="

echo "$K_POINTS_LINE"

echo ""

echo "Note: CELL_PARAMETERS / ATOMIC_POSITIONS come from extract_structure.sh"
echo "(run after relax), not from parser.sh. Check cache/structure.in for those."
