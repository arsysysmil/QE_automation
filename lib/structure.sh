#!/bin/bash
# Pulling the relaxed geometry out of the relax output.
#
# Sourced by qe.sh. Not executable on its own.

extract_final_cell() {
    local relax_out="$1"

    awk '
    /^[[:space:]]*Begin final coordinates/ { final = 1 }
    final && /^[[:space:]]*CELL_PARAMETERS/ {
        header = $0
        getline v1; getline v2; getline v3

        if (tolower(header) ~ /alat[[:space:]]*=/) {
            alat = header
            sub(/.*[Aa][Ll][Aa][Tt][[:space:]]*=[[:space:]]*/, "", alat)
            sub(/[^0-9.eEdD+-].*$/, "", alat)
            if (alat + 0 <= 0) {
                print "ERROR: could not read the alat value out of the final" \
                      " CELL_PARAMETERS header: " header > "/dev/stderr"
                exit 1
            }
            scale = (alat + 0) * 0.529177210903   # bohr -> angstrom
            print "CELL_PARAMETERS (angstrom)"
            split(v1, a); printf "  %.10f  %.10f  %.10f\n", a[1]*scale, a[2]*scale, a[3]*scale
            split(v2, b); printf "  %.10f  %.10f  %.10f\n", b[1]*scale, b[2]*scale, b[3]*scale
            split(v3, c); printf "  %.10f  %.10f  %.10f\n", c[1]*scale, c[2]*scale, c[3]*scale
        } else {
            print header; print v1; print v2; print v3
        }
        exit
    }
    ' "$relax_out"
}

step_extract() {
    require_cache

    if [[ ! -f "$RELAX_OUT" ]]; then
        echo "ERROR: $RELAX_OUT not found."
        exit 1
    fi

    local CELL_BLOCK ATOMIC_BLOCK CELL_SOURCE

    # A vc-relax moves the cell, and QE prints the converged one in the
    # "Begin final coordinates" block of the output. Until 2026-07-27 this
    # read CELL_PARAMETERS from the *input* while reading ATOMIC_POSITIONS
    # from the output, so every later step ran on the un-relaxed cell holding
    # the relaxed positions - a structure that was never optimised and never
    # reported as wrong. It also made the pipeline's "relaxed lattice
    # constant" identical to the input value by construction.
    #
    # A plain 'relax' does not move the cell and prints no CELL_PARAMETERS,
    # so falling back to the input block is correct there, not a workaround.
    CELL_BLOCK=$(extract_final_cell "$RELAX_OUT")

    if [[ -n "$CELL_BLOCK" ]]; then
        CELL_SOURCE="relaxed cell from $(basename "$RELAX_OUT")"
    else
        CELL_BLOCK=$(awk '
        /^[[:space:]]*CELL_PARAMETERS[[:space:]]*/ {
            print; getline; print; getline; print; getline; print
            exit
        }
        ' "$RELAX_IN")
        CELL_SOURCE="input cell from $(basename "$RELAX_IN")"

        if [[ "${CALCULATION,,}" == vc-* ]]; then
            echo "WARNING: calculation is '$CALCULATION', which relaxes the cell, but"
            echo "         no final CELL_PARAMETERS was found in $RELAX_OUT."
            echo "         Falling back to the input cell - check that the relax"
            echo "         actually reached 'Begin final coordinates'."
        fi
    fi

    if [[ -z "$CELL_BLOCK" ]]; then
        echo "ERROR: no CELL_PARAMETERS block in $RELAX_OUT or $RELAX_IN."
        echo "       An ibrav /= 0 input has none; this pipeline needs ibrav = 0"
        echo "       with an explicit CELL_PARAMETERS card."
        exit 1
    fi

    ATOMIC_BLOCK=$(awk '
    /^[[:space:]]*ATOMIC_POSITIONS[[:space:]]*/ {
        header=$0; n=0; capture=1; delete block; next
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

    echo "Structure extracted: $STRUCTURE_FILE"
    echo "  cell     : $CELL_SOURCE"
    echo "  positions: relaxed positions from $(basename "$RELAX_OUT")"
}

