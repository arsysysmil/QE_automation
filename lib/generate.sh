#!/bin/bash
# Writing the generated scf / band / nscf inputs.
#
# Sourced by qe.sh. Not executable on its own.

emit_pw_input() {
    local calculation="$1"
    local outfile="$2"

    cat > "$outfile" <<EOF
&CONTROL
    calculation = '$calculation'
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    pseudo_dir = '$PSEUDO_DIR'
EOF

    [[ -n "${CONTROL_EXTRA:-}" ]] && printf '%s\n' "$CONTROL_EXTRA" >> "$outfile"

    cat >> "$outfile" <<EOF
/

&SYSTEM
    ibrav = $IBRAV
    nat = $NAT
    ntyp = $NTYP
    ecutwfc = $ECUTWFC
EOF

    [[ -n "${ECUTRHO:-}" ]]  && echo "    ecutrho = $ECUTRHO"      >> "$outfile"
    echo "    occupations = '$OCCUPATIONS'"                        >> "$outfile"
    [[ -n "${SMEARING:-}" ]] && echo "    smearing = '$SMEARING'"  >> "$outfile"
    [[ -n "${DEGAUSS:-}" ]]  && echo "    degauss = $DEGAUSS"      >> "$outfile"

    # Everything else the input declared in &SYSTEM: nbnd, nspin,
    # starting_magnetization, vdw_corr, edir/emaxpos/eopreg/eamp, ...
    [[ -n "${SYSTEM_EXTRA:-}" ]] && printf '%s\n' "$SYSTEM_EXTRA" >> "$outfile"

    cat >> "$outfile" <<EOF
/

&ELECTRONS
    conv_thr = $CONV_THR
    mixing_beta = $MIXING_BETA
EOF

    [[ -n "${ELECTRONS_EXTRA:-}" ]] && printf '%s\n' "$ELECTRONS_EXTRA" >> "$outfile"

    cat >> "$outfile" <<EOF
/

ATOMIC_SPECIES
$ATOMIC_SPECIES

EOF

    cat "$STRUCTURE_FILE" >> "$outfile"
}

# Cards the input declared that this script does not build itself - HUBBARD
# above all. Appended after the K_POINTS card, which is why every generator
# calls it last rather than emit_pw_input doing it: card order is free in QE,
# but K_POINTS is written by the caller, not by emit_pw_input.
emit_extra_cards() {
    local outfile="$1"
    [[ -z "${EXTRA_CARDS:-}" ]] && return 0
    printf '\n%s\n' "$EXTRA_CARDS" >> "$outfile"
}

# The k-point card for a self-consistent-style step, reproducing whatever
# sampling the input asked for.
emit_kpoints_as_input() {
    local outfile="$1"

    if [[ "${K_POINTS_MODE:-automatic}" == "gamma" ]]; then
        printf '\nK_POINTS gamma\n' >> "$outfile"
    else
        printf '\nK_POINTS automatic\n%s\n' "$K_POINTS" >> "$outfile"
    fi
}

step_gen_scf() {
    require_cache
    require_structure

    emit_pw_input scf "$SCF_IN"
    emit_kpoints_as_input "$SCF_IN"
    emit_extra_cards "$SCF_IN"

    echo "SCF input generated: $SCF_IN"
}

step_gen_band() {
    require_cache
    require_structure

    # The high-symmetry path depends entirely on the Bravais lattice.
    # Gamma-M-K-Gamma is correct only for hexagonal cells, so each case
    # supplies its own path rather than silently inheriting one that would
    # be wrong (and wrong *quietly*) for other symmetries.
    if [[ ! -f "$BAND_PATH_FILE" ]]; then
        echo "ERROR: no band path found for case '$CASE_NAME'."
        echo "Create $BAND_PATH_FILE with the K_POINTS block for this"
        echo "material's own high-symmetry path (use __BAND_POINTS__ where the"
        echo "per-segment point count from config.sh should be substituted)."
        echo "Hexagonal example (graphene/MoS2/WS2-like only):"
        echo "  $ROOT_DIR/template/band.path.hexagonal_example"
        exit 1
    fi

    emit_pw_input bands "$BAND_IN"
    echo "" >> "$BAND_IN"
    sed "s/__BAND_POINTS__/${BAND_POINTS}/g" "$BAND_PATH_FILE" >> "$BAND_IN"
    emit_extra_cards "$BAND_IN"

    echo "Band input generated: $BAND_IN"
}

step_gen_nscf() {
    require_cache
    require_structure

    local KPOINTS_CLEAN KX KY KZ SX SY SZ

    # A gamma-only case has no mesh to densify. Scaling "1 1 1" up would turn
    # an isolated molecule's sampling into a 2x2x2 mesh of a vacuum box, which
    # is just wasted work, so the sampling is reproduced as-is.
    if [[ "${K_POINTS_MODE:-automatic}" == "gamma" ]]; then
        emit_pw_input nscf "$NSCF_IN"
        emit_kpoints_as_input "$NSCF_IN"
        emit_extra_cards "$NSCF_IN"
        echo "NSCF input generated: $NSCF_IN"
        echo "  note: gamma-only case, no k-mesh to scale (NSCF_KPOINT_SCALE ignored)"
        return 0
    fi

    KPOINTS_CLEAN="${K_POINTS%%!*}"
    read -r KX KY KZ SX SY SZ <<< "$KPOINTS_CLEAN"

    if [[ -z "${KX:-}" || -z "${KY:-}" || -z "${KZ:-}" ]]; then
        echo "ERROR: failed to parse K_POINTS from $CACHE_FILE"
        exit 1
    fi

    SX="${SX:-0}"; SY="${SY:-0}"; SZ="${SZ:-0}"

    KX=$((KX * NSCF_KPOINT_SCALE))
    KY=$((KY * NSCF_KPOINT_SCALE))

    # Only a cell the input declares as 2D keeps its single k-point along z.
    if [[ "${CELL_DOFREE,,}" != 2d* ]]; then
        KZ=$((KZ * NSCF_KPOINT_SCALE))
    fi

    emit_pw_input nscf "$NSCF_IN"
    printf '\nK_POINTS automatic\n%s %s %s %s %s %s\n' \
        "$KX" "$KY" "$KZ" "$SX" "$SY" "$SZ" >> "$NSCF_IN"
    emit_extra_cards "$NSCF_IN"

    echo "NSCF input generated: $NSCF_IN"
}

