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

    # Set by resolve_auto_nbnd(), and only ever for the band and nscf steps.
    # Empty whenever the input declares nbnd itself, in which case the value
    # arrives through SYSTEM_EXTRA below and this must not write a second one.
    [[ -n "${EMIT_NBND:-}" ]] && echo "    nbnd = $EMIT_NBND"       >> "$outfile"

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

#############################
# How many bands the band and nscf steps ask for
#############################
#
# QE's own default leaves a band plot with nothing to show above the Fermi
# level. Under occupations='fixed' it is nelec/2 exactly - zero conduction
# bands, so the upper half of both the band and the DOS figure comes out
# empty - and under smearing it is max(1.2*nelec/2, nelec/2+4), which is thin
# for a figure. Neither is wrong for an scf, whose job is the charge density;
# both are wrong for the two steps whose whole purpose is the empty states.
#
# So the band and nscf steps ask for AUTO_NBND_FACTOR x the occupied count,
# and say what they picked. The scf step is deliberately left alone: empty
# bands cost it time and buy it nothing.
#
# An input that sets nbnd itself always wins. It arrives through SYSTEM_EXTRA
# and nothing is added here.

# True when the input declared nbnd, in which case it is already in
# SYSTEM_EXTRA and will be emitted from there.
input_sets_nbnd() {
    [[ -n "${SYSTEM_EXTRA:-}" ]] || return 1
    grep -qiE '^[[:space:]]*nbnd[[:space:]]*=' <<< "$SYSTEM_EXTRA"
}

# z_valence out of a pseudopotential file. UPF v2 keeps it as an attribute of
# the PP_HEADER tag; UPF v1 as a bare labelled line. Empty if neither is found.
upf_z_valence() {
    local upf="$1"
    [[ -f "$upf" ]] || return 0

    awk '
        match($0, /z_valence="[^"]*"/) {
            print substr($0, RSTART + 11, RLENGTH - 12) + 0
            exit
        }
        /Z valence/ { print $1 + 0; exit }
    ' "$upf"
}

# How many atoms of one species the relaxed structure holds. The card runs
# until a blank line or the start of another card, both of which have fewer
# than the four fields an atom line carries.
count_atoms_of_species() {
    awk -v want="$1" '
        /ATOMIC_POSITIONS/ { inblock = 1; next }
        !inblock { next }
        NF < 4 { exit }
        $1 == want { n++ }
        END { print n + 0 }
    ' "$STRUCTURE_FILE"
}

# Valence electrons in the cell, or empty when neither source can say.
valence_electron_count() {
    local nelec="" label upf z n total=0 counted=0

    # The scf output states it outright, and in a full pipeline the scf has
    # run before either generator does.
    if [[ -f "$SCF_OUT" ]]; then
        nelec="$(awk '/number of electrons/ { print $5; exit }' "$SCF_OUT")"
        if [[ -n "$nelec" ]]; then
            printf '%s\n' "$nelec"
            return 0
        fi
    fi

    # gen-band or gen-nscf run on their own, before any scf: add up z_valence
    # over the pseudopotentials instead. One species whose UPF cannot be read
    # makes the whole sum wrong, so that gives up rather than under-counting.
    while read -r label _ upf _; do
        [[ -n "$label" && -n "$upf" ]] || continue

        z="$(upf_z_valence "$PSEUDO_DIR/$upf")"
        [[ -n "$z" ]] || return 0

        n="$(count_atoms_of_species "$label")"
        (( n > 0 )) || continue

        total="$(awk -v t="$total" -v z="$z" -v n="$n" 'BEGIN { print t + z * n }')"
        counted=1
    done <<< "$ATOMIC_SPECIES"

    (( counted )) && printf '%s\n' "$total"
    return 0
}

# Bands occupied at zero temperature. nbnd counts spinor states when noncolin
# is on, so all nelec of them are occupied there; otherwise a band holds two
# electrons. Under nspin=2 nbnd is per channel, which is nelec/2 again.
occupied_band_count() {
    local nelec="$1"

    if [[ "${NONCOLIN,,}" == *true* ]]; then
        awk -v n="$nelec" 'BEGIN { printf "%d\n", int(n + 0.5) }'
    else
        awk -v n="$nelec" 'BEGIN { printf "%d\n", int(n / 2 + 0.999) }'
    fi
}

# What QE would pick if nbnd were left out, for the note printed below.
qe_default_nbnd() {
    local occ="$1"

    if [[ "${OCCUPATIONS:-fixed}" == "fixed" ]]; then
        printf '%s\n' "$occ"
    else
        awk -v occ="$occ" 'BEGIN {
            a = int(occ * 1.2); b = occ + 4
            printf "%d\n", (a > b) ? a : b
        }'
    fi
}

# Sets EMIT_NBND for the step named in $1, and says what it decided.
resolve_auto_nbnd() {
    local step="$1"
    local factor="${AUTO_NBND_FACTOR:-1.5}"
    local nelec occ nbnd qe_default

    EMIT_NBND=""

    input_sets_nbnd && return 0
    [[ "$factor" == "0" || -z "$factor" ]] && return 0

    nelec="$(valence_electron_count)"
    if [[ -z "$nelec" ]]; then
        echo "  note: nbnd absent from input, and the electron count could not be"
        echo "        determined here - leaving nbnd to QE. Run the scf step first,"
        echo "        or set nbnd in &SYSTEM."
        return 0
    fi

    occ="$(occupied_band_count "$nelec")"
    (( occ > 0 )) || return 0

    nbnd="$(awk -v occ="$occ" -v f="$factor" 'BEGIN {
        a = int(occ * f + 0.999); b = occ + 4
        printf "%d\n", (a > b) ? a : b
    }')"

    qe_default="$(qe_default_nbnd "$occ")"

    EMIT_NBND="$nbnd"
    echo "  note: nbnd absent from input - $step uses nbnd = $nbnd"
    echo "        ($nelec electrons, $occ occupied bands, x$factor)."
    echo "        QE's own default here would be $qe_default, which leaves" \
         "$(( qe_default - occ )) band(s)"
    echo "        above the Fermi level. Set nbnd in &SYSTEM to choose your own,"
    echo "        or AUTO_NBND_FACTOR in config.sh to change this rule."
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

    # No auto nbnd here on purpose: see the block above.
    EMIT_NBND=""

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
        echo "  $ROOT_DIR/template/band.path.hex_gamma60_example"
        exit 1
    fi

    resolve_auto_nbnd band

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

    resolve_auto_nbnd nscf

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

