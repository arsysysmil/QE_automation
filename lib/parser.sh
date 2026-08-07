#!/bin/bash
# Reading the relax input: parameters, passthrough, parser.cache.
#
# Sourced by qe.sh. Not executable on its own.

# One value out of the input, by key.
#
# The trailing comment is cut before anything else. Without that,
# `ecutwfc = 60   ! Ry, converged` came through as the value "60   ! Ry
# converged" (the comma stripped by the quote rule, so it was not even the
# text the user wrote) and was copied verbatim into every generated input.
# Fortran namelist reads tolerated it, so nothing ever broke - but `qe.sh
# dump`, which exists to show what the parser sees, showed the wrong value,
# and namelist_passthrough() below already stripped comments, so the two
# halves of the parser disagreed about what a line means.
get_param() {
    local key="$1"
    grep -iE "^[[:space:]]*${key}[[:space:]]*=" "$INPUT_ABS" \
        | head -1 \
        | sed -E "s/^[^=]*=[[:space:]]*//; s/!.*//; s/[',]//g; s/[[:space:]]+$//" \
        || true
}

# Everything the input declares inside one namelist, minus the keys this
# script writes itself.
#
# get_param() knows 16 keys. Everything else the input declares - nbnd, nspin,
# starting_magnetization, vdw_corr, tefield/dipfield, edir, tot_charge,
# input_dft, assume_isolated - has to reach the generated scf/band/nscf inputs
# too, or they describe different physics from the relax with no error to say
# so.
#
# Copied as raw lines rather than parsed into variables, so indexed keys
# (starting_magnetization(1) = 0.5) and forms this script has never heard of
# come through untouched.
namelist_passthrough() {
    local nml_pat="$1"   # lowercase, e.g. '^[ \t]*&system[ \t]*$'
    local drop_keys="$2" # alternation, e.g. 'ibrav|nat|ntyp'

    awk -v pat="$nml_pat" '
    { raw = $0; sub(/!.*/, "", raw); low = tolower(raw) }
    !inside && low ~ pat { inside = 1; next }
    inside && raw ~ /^[[:space:]]*(\/|&[Ee][Nn][Dd])[[:space:]]*$/ { exit }
    inside { print raw }
    ' "$INPUT_ABS" \
        | grep -viE "^[[:space:]]*(${drop_keys})[[:space:]]*(\([^)]*\))?[[:space:]]*=" \
        | grep -vE "^[[:space:]]*$" \
        || true
}

# Keys the generator writes itself, so passing them through as well would
# duplicate them inside the namelist.
#
# &CONTROL additionally drops the relax-only ones: restart_mode would make a
# fresh scf try to restart, and nstep/etot_conv_thr/forc_conv_thr mean nothing
# outside a relax. tefield/dipfield are deliberately NOT dropped - they belong
# with edir/emaxpos/eopreg/eamp in &SYSTEM, and keeping only half of that pair
# turns the dipole correction off without saying so.
DROP_CONTROL='calculation|prefix|outdir|pseudo_dir|restart_mode|nstep|etot_conv_thr|forc_conv_thr'

# celldm/A/B/C/cosAB/cosAC/cosBC are dropped because the lattice now comes
# from cache/structure.in as an explicit CELL_PARAMETERS block; leaving a
# second, stale definition of the same cell in &SYSTEM is how they disagree.
DROP_SYSTEM='ibrav|nat|ntyp|ecutwfc|ecutrho|occupations|smearing|degauss|celldm|a|b|c|cosab|cosac|cosbc'

DROP_ELECTRONS='conv_thr|mixing_beta'

# Cards worth carrying from the relax input into every generated input, in
# the order they appear. A card runs from its header to the next card header
# or end of file; blank lines inside it are kept, trailing ones trimmed.
CARDS_KEPT='HUBBARD|OCCUPATIONS'

# Every card name pw.x knows, so the end of one card can be recognised
# without knowing which card comes next.
CARDS_ALL='ATOMIC_SPECIES|ATOMIC_POSITIONS|K_POINTS|CELL_PARAMETERS|HUBBARD|OCCUPATIONS|CONSTRAINTS|ATOMIC_VELOCITIES|ATOMIC_FORCES|ADDITIONAL_K_POINTS|SOLVENTS'

# The ATOMIC_SPECIES card of $INPUT_ABS, one species per line.
#
# Stops at a blank line OR at the next card header. Blank-line-only was too
# fragile: an input whose ATOMIC_SPECIES card is followed directly by
# ATOMIC_POSITIONS, with no blank line between them, had the whole positions
# card swallowed into the species list - and the generated inputs then carried
# a mangled ATOMIC_SPECIES that QE rejected with an error pointing nowhere near
# the real cause.
#
# A function rather than inline in step_parser() because the pseudopotential
# preflight needs the same list before any step runs, and two readers of one
# card would eventually disagree about where it ends.
atomic_species_block() {
    awk -v any="^[[:space:]]*($CARDS_ALL)([[:space:]]|\\\\(|\\\\{|$)" '
    /^[[:space:]]*ATOMIC_SPECIES[[:space:]]*$/ {flag=1; next}
    flag && /^[[:space:]]*$/ {exit}
    flag && $0 ~ any {exit}
    flag {print}
    ' "$INPUT_ABS"
}

# Where pw.x will look for pseudopotentials, as an absolute path.
#
# A relative pseudo_dir is resolved against the directory holding the input,
# because that is where run_pw() cd's to before launching pw.x - not against
# wherever qe.sh happened to be invoked from.
pseudo_dir_abs() {
    local dir
    dir="$(get_param pseudo_dir)"

    [[ -n "$dir" ]] || return 1
    [[ "$dir" == /* ]] || dir="$(dirname "$INPUT_ABS")/$dir"

    printf '%s' "$dir"
}

# Everything about this case's pseudopotentials that is not on disk, as a block
# ready to print. Nothing at all when they are all there.
#
# Checked before the queue rather than by pw.x, which discovers it seconds into
# a job that may have waited hours to start. The WS2 screening is the case that
# makes it worth doing: twenty inputs whose pseudo_dir had to be rewritten by
# hand when they moved between accounts, where one missed line costs a whole
# queue wait to find out about.
pseudo_problems() {
    local input_abs="$1"
    local dir upf sym mass rest
    local -a missing=()

    INPUT_ABS="$input_abs"

    if ! dir="$(pseudo_dir_abs)"; then
        printf '  %s\n    no pseudo_dir line in this input\n' "$(basename "$input_abs")"
        return 0
    fi

    if [[ ! -d "$dir" ]]; then
        printf '  %s\n    pseudo_dir : %s\n' "$(basename "$input_abs")" "$dir"
        printf '    -> no such directory, or it cannot be read from this machine\n'
        return 0
    fi

    while read -r sym mass upf rest; do
        [[ -n "${upf:-}" ]] || continue
        [[ -f "$dir/$upf" ]] || missing+=("$upf")
    done < <(atomic_species_block)

    (( ${#missing[@]} )) || return 0

    printf '  %s\n    pseudo_dir : %s\n    missing    : %s\n' \
        "$(basename "$input_abs")" "$dir" "${missing[*]}"
}

# Every pseudopotential file this case names, as absolute paths - so the
# preflight can say how many distinct files it checked.
pseudo_files_of() {
    local input_abs="$1"
    local dir upf sym mass rest

    INPUT_ABS="$input_abs"
    dir="$(pseudo_dir_abs)" || return 0

    while read -r sym mass upf rest; do
        [[ -n "${upf:-}" ]] || continue
        printf '%s/%s\n' "$dir" "$upf"
    done < <(atomic_species_block)
}

extract_cards() {
    local infile="$1"

    awk -v keep="^[[:space:]]*($CARDS_KEPT)([[:space:]]|\\\\(|\\\\{|$)" \
        -v any="^[[:space:]]*($CARDS_ALL)([[:space:]]|\\\\(|\\\\{|$)" '
    $0 ~ any { copying = ($0 ~ keep) }
    copying  { print }
    ' "$infile" \
        | sed -E '$ { /^[[:space:]]*$/ d; }'
}

announce_passthrough() {
    local nml="$1" block="$2"
    [[ -z "$block" ]] && return 0
    echo "  passthrough &${nml}: $(
        printf '%s\n' "$block" \
            | sed -E 's/^[[:space:]]*//; s/[[:space:]]*=.*//' \
            | tr '\n' ' ')"
}

# Bumped whenever the cache gains a field, so a cache written by an older
# qe.sh is rebuilt instead of silently sourced with the new fields missing -
# which would look exactly like the passthrough not working.
# Kept under a different name from the CACHE_VERSION the cache file itself
# sets, because sourcing the cache would otherwise overwrite the value it is
# about to be compared against.
CACHE_VERSION_EXPECTED='4'

step_parser() {
    local PREFIX OUTDIR PSEUDO_DIR CALCULATION
    local IBRAV NAT NTYP ECUTWFC ECUTRHO
    local OCCUPATIONS SMEARING DEGAUSS CONV_THR MIXING_BETA CELL_DOFREE
    local NSPIN NONCOLIN
    local ATOMIC_SPECIES_BLOCK K_POINTS_LINE K_POINTS_MODE EXTRA_CARDS_BLOCK
    local CONTROL_EXTRA_BLOCK SYSTEM_EXTRA_BLOCK ELECTRONS_EXTRA_BLOCK

    # An absent prefix defaults to the CASE NAME, not to QE's own 'pwscf'.
    #
    # bands.x and dos.x name their output after the prefix - <prefix>.dos,
    # <prefix>.bands.dat.gnu - and so does the save directory inside outdir.
    # QE's own 'pwscf' default would give every case in a folder the same file
    # names, leaving one pwscf.dos: whichever ran last.
    #
    # An input that sets prefix itself still wins - and qe.sh refuses to start
    # when two cases in one directory would end up sharing one.
    PREFIX=$(get_param prefix);   [[ -z "$PREFIX" ]] && PREFIX="$CASE_NAME"
    OUTDIR=$(get_param outdir);   [[ -z "$OUTDIR" ]] && OUTDIR="./work"

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

    # Values the input omits fall back to config.sh's DEFAULT_* entries. The
    # DEFAULT_ prefix is required: a bare SMEARING/DEGAUSS/MIXING_BETA in
    # config.sh would collide with these variables and overwrite what the
    # input file said.
    CONV_THR=$(get_param conv_thr)
    if [[ -z "$CONV_THR" ]]; then
        CONV_THR="${DEFAULT_CONV_THR:-1.0d-6}"
        echo "  note: conv_thr absent from input, using default $CONV_THR"
    fi

    MIXING_BETA=$(get_param mixing_beta)
    if [[ -z "$MIXING_BETA" ]]; then
        MIXING_BETA="${DEFAULT_MIXING_BETA:-0.7}"
        echo "  note: mixing_beta absent from input, using default $MIXING_BETA"
    fi

    # Tells the nscf step whether this is a 2D slab or a normal 3D cell.
    CELL_DOFREE=$(get_param cell_dofree)

    # Read for information only - nspin and noncolin stay in SYSTEM_EXTRA and
    # are emitted from there. They are named here because step_bandsx has to
    # KNOW the calculation is spin-polarised: bands.x writes
    # one spin channel per run and defaults to the first, so an nspin=2 case
    # needs two passes. Deliberately NOT added to DROP_SYSTEM - dropping them
    # from the passthrough would remove them from the generated inputs.
    NSPIN=$(get_param nspin)
    NONCOLIN=$(get_param noncolin)

    ATOMIC_SPECIES_BLOCK=$(atomic_species_block)

    # The card's own mode word decides how the k-points may be handled later:
    # 'automatic' is a mesh that the nscf step can scale, 'gamma' is a single
    # point that must be reproduced verbatim, and an explicit list cannot be
    # scaled at all. Reading only the line *after* the header, as this did,
    # made a gamma-only molecule look like a missing K_POINTS card.
    K_POINTS_MODE=$(grep -iE "^[[:space:]]*K_POINTS" "$INPUT_ABS" \
        | head -1 \
        | sed -E 's/^[[:space:]]*[Kk]_[Pp][Oo][Ii][Nn][Tt][Ss][[:space:]]*//; s/[{}()]//g; s/!.*//; s/[[:space:]]//g' \
        | tr 'A-Z' 'a-z')

    # QE's own default when the mode word is omitted.
    [[ -z "$K_POINTS_MODE" ]] && K_POINTS_MODE="tpiba"

    K_POINTS_LINE=""
    if [[ "$K_POINTS_MODE" == "automatic" ]]; then
        K_POINTS_LINE=$(awk '
        /^[[:space:]]*K_POINTS[[:space:]]*/ {
            getline
            sub(/!.*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print
            exit
        }
        ' "$INPUT_ABS")
    fi

    # Cards other than the four this script builds itself. HUBBARD is the one
    # that matters: DFT+U is written as a card in QE 7.x, not as &SYSTEM keys,
    # so it was dropped after the relax and every later step ran plain PBE -
    # an antiferromagnetic insulator like NiO comes out metallic, silently.
    # OCCUPATIONS carries an explicit per-band occupation list.
    #
    # CONSTRAINTS / ATOMIC_VELOCITIES / ATOMIC_FORCES are deliberately not
    # carried: they only mean something to a relax or an MD run.
    EXTRA_CARDS_BLOCK=$(extract_cards "$INPUT_ABS")

    if [[ -z "$PSEUDO_DIR" ]]; then
        echo "ERROR: pseudo_dir not found in $INPUT_ABS"
        exit 1
    fi

    local var
    for var in NAT NTYP ECUTWFC IBRAV; do
        if [[ -z "${!var}" ]]; then
            echo "ERROR: $var not found in $INPUT_ABS"
            if [[ "$var" == "IBRAV" ]]; then
                echo "       Add 'ibrav = 0' to &SYSTEM. Without it the generated"
                echo "       inputs would carry an empty 'ibrav =' and pw.x would"
                echo "       fail on the namelist several steps later."
            fi
            exit 1
        fi
    done

    # The geometry is handed between steps as an explicit CELL_PARAMETERS
    # card, which only exists for ibrav = 0. Any other value describes the
    # lattice through celldm/A/B/C instead, and there is nothing to extract.
    # Caught here rather than in step_extract so it costs seconds, not a relax.
    if [[ "$IBRAV" != "0" ]]; then
        echo "ERROR: ibrav = $IBRAV in $INPUT_ABS, but this pipeline needs ibrav = 0."
        echo "       Steps pass the geometry to each other as a CELL_PARAMETERS"
        echo "       card, which an ibrav /= 0 input does not have."
        echo "       FIX: set ibrav = 0 and write the three lattice vectors as an"
        echo "       explicit CELL_PARAMETERS card."
        exit 1
    fi

    # QE itself treats a missing `occupations` as 'fixed', so rejecting an
    # input that omits it would be stricter than QE. 'fixed' is only right for
    # a system with a gap; a metal needs occupations='smearing' spelled out.
    if [[ -z "$OCCUPATIONS" ]]; then
        OCCUPATIONS="${DEFAULT_OCCUPATIONS:-fixed}"
        echo "  note: occupations absent from input, using default '$OCCUPATIONS'"
        echo "        (correct for insulators/semiconductors; a metal needs"
        echo "         occupations='smearing' set explicitly)"
    fi

    # smearing/degauss only mean anything when occupations actually smears;
    # 'fixed' and 'tetrahedra*' legitimately omit them, and must keep them
    # empty so they are not emitted into the generated inputs at all.
    if [[ "${OCCUPATIONS,,}" == "smearing" ]]; then
        if [[ -z "$SMEARING" ]]; then
            SMEARING="${DEFAULT_SMEARING:-mv}"
            echo "  note: smearing absent from input, using default '$SMEARING'"
        fi
        if [[ -z "$DEGAUSS" ]]; then
            DEGAUSS="${DEFAULT_DEGAUSS:-0.02}"
            echo "  note: degauss absent from input, using default $DEGAUSS"
        fi
    fi

    if [[ -z "$ATOMIC_SPECIES_BLOCK" ]]; then
        echo "ERROR: ATOMIC_SPECIES block not found in $INPUT_ABS"
        exit 1
    fi

    # Checked here, in the first step, rather than in the nscf generator that
    # needs it. Otherwise an unsupported K_POINTS form aborts only after the
    # relax, scf, band and bands.x steps have already run.
    case "$K_POINTS_MODE" in
        automatic)
            if [[ -z "$K_POINTS_LINE" ]]; then
                echo "ERROR: 'K_POINTS automatic' in $INPUT_ABS is not followed by a mesh line."
                exit 1
            fi
            if ! [[ "${K_POINTS_LINE%%!*}" =~ ^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+ ]]; then
                echo "ERROR: cannot read a 'nk1 nk2 nk3' mesh from the K_POINTS line"
                echo "       in $INPUT_ABS: '$K_POINTS_LINE'"
                exit 1
            fi
            ;;
        gamma)
            # A single point cannot be split across pools.
            if (( NPOOL > 1 )); then
                echo "ERROR: this case is gamma-only, but NPOOL is $NPOOL."
                echo "       Pools divide the k-points between rank groups and there is"
                echo "       only one k-point, so all but one pool would idle."
                echo "       FIX: set NPOOL=1 in config.sh for gamma-only cases."
                exit 1
            fi
            ;;
        *)
            echo "ERROR: K_POINTS mode '$K_POINTS_MODE' in $INPUT_ABS is not supported."
            echo "       This pipeline needs a mesh it can scale for the nscf/DOS step,"
            echo "       so the relax input must use 'K_POINTS automatic' (or 'gamma'"
            echo "       for an isolated molecule). An explicit k-point list has no mesh"
            echo "       to scale."
            echo "       The band step is unaffected either way - it always takes its"
            echo "       path from ${CASE_NAME}_band.path."
            exit 1
            ;;
    esac

    CONTROL_EXTRA_BLOCK=$(namelist_passthrough '^[ \t]*&control[ \t]*$'   "$DROP_CONTROL")
    SYSTEM_EXTRA_BLOCK=$(namelist_passthrough  '^[ \t]*&system[ \t]*$'    "$DROP_SYSTEM")
    ELECTRONS_EXTRA_BLOCK=$(namelist_passthrough '^[ \t]*&electrons[ \t]*$' "$DROP_ELECTRONS")

    # Say out loud what is being carried over. These are exactly the settings
    # whose silent loss changes the physics without changing the exit code.
    announce_passthrough CONTROL   "$CONTROL_EXTRA_BLOCK"
    announce_passthrough SYSTEM    "$SYSTEM_EXTRA_BLOCK"
    announce_passthrough ELECTRONS "$ELECTRONS_EXTRA_BLOCK"

    if [[ -n "$EXTRA_CARDS_BLOCK" ]]; then
        echo "  passthrough cards  : $(
            printf '%s\n' "$EXTRA_CARDS_BLOCK" \
                | grep -iE "^[[:space:]]*($CARDS_KEPT)" \
                | sed -E 's/^[[:space:]]*//' \
                | tr '\n' ' ')"
    fi

    cat > "$CACHE_FILE" <<EOF
CACHE_VERSION='${CACHE_VERSION_EXPECTED}'

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

CELL_DOFREE='${CELL_DOFREE}'
NSPIN='${NSPIN}'
NONCOLIN='${NONCOLIN}'

ATOMIC_SPECIES=\$(cat <<'EOF_ATOMIC_SPECIES'
${ATOMIC_SPECIES_BLOCK}
EOF_ATOMIC_SPECIES
)

CONTROL_EXTRA=\$(cat <<'EOF_CONTROL_EXTRA'
${CONTROL_EXTRA_BLOCK}
EOF_CONTROL_EXTRA
)

SYSTEM_EXTRA=\$(cat <<'EOF_SYSTEM_EXTRA'
${SYSTEM_EXTRA_BLOCK}
EOF_SYSTEM_EXTRA
)

ELECTRONS_EXTRA=\$(cat <<'EOF_ELECTRONS_EXTRA'
${ELECTRONS_EXTRA_BLOCK}
EOF_ELECTRONS_EXTRA
)

EXTRA_CARDS=\$(cat <<'EOF_EXTRA_CARDS'
${EXTRA_CARDS_BLOCK}
EOF_EXTRA_CARDS
)

K_POINTS_MODE='${K_POINTS_MODE}'
K_POINTS='${K_POINTS_LINE}'
EOF

    echo "Parser cache saved:"
    echo "$CACHE_FILE"
}

step_dump() {
    # Always re-parses, rather than requiring `parser` to have been run first.
    # Two reasons: this is the command a first-time user is told to run to
    # check their input, and failing it with "run the 'parser' step first" is
    # a pointless obstacle; and its whole purpose is to show what the input
    # says *now*, so reading a cache written before the last edit would be
    # worse than useless - it would be misleading.
    step_parser
    echo ""
    source "$CACHE_FILE"

    printf '%-14s: %s\n' \
        PREFIX "$PREFIX" OUTDIR "$OUTDIR" PSEUDO_DIR "$PSEUDO_DIR" \
        CALCULATION "$CALCULATION" IBRAV "$IBRAV" NAT "$NAT" NTYP "$NTYP" \
        ECUTWFC "$ECUTWFC" ECUTRHO "$ECUTRHO" OCCUPATIONS "$OCCUPATIONS" \
        SMEARING "$SMEARING" DEGAUSS "$DEGAUSS" CONV_THR "$CONV_THR" \
        MIXING_BETA "$MIXING_BETA" CELL_DOFREE "$CELL_DOFREE" \
        NSPIN "${NSPIN:-}" NONCOLIN "${NONCOLIN:-}" \
        K_POINTS_MODE "${K_POINTS_MODE:-}" K_POINTS "$K_POINTS"
    echo "ATOMIC_SPECIES:"
    echo "$ATOMIC_SPECIES"

    local nml
    for nml in CONTROL SYSTEM ELECTRONS; do
        echo "&${nml} passthrough:"
        case "$nml" in
            CONTROL)   printf '%s\n' "${CONTROL_EXTRA:-  (none)}" ;;
            SYSTEM)    printf '%s\n' "${SYSTEM_EXTRA:-  (none)}" ;;
            ELECTRONS) printf '%s\n' "${ELECTRONS_EXTRA:-  (none)}" ;;
        esac
    done

    echo "cards carried over:"
    printf '%s\n' "${EXTRA_CARDS:-  (none)}"
}

#############################
