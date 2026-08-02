#!/bin/bash
# Writing the structure out as CIF.
#
# Sourced by qe.sh. Not executable on its own.
#
# Two files per case, so the relaxation can be looked at rather than trusted:
#
#   <case>_initial.cif   the geometry as written in <case>_relax.in
#   <case>_relaxed.cif   the geometry pw.x converged to
#
# Both come from data the workflow already has - the input, and the
# cache/<case>.structure.in that step_extract() produced - so this reads no
# wavefunctions, needs no MPI, and can be run on a finished case at any time.
#
# Symmetry is written as P 1, always. Guessing a space group from relaxed
# coordinates is how a CIF comes out subtly wrong with nothing to say so, and
# every viewer worth using (VESTA, OVITO, ASE) re-detects symmetry itself with
# a tolerance you can see. The same reasoning as the band path: refuse to
# guess rather than produce a plausible-looking answer.

CIF_BOHR_TO_ANG='0.529177210903'

# Turn one file holding a CELL_PARAMETERS card and an ATOMIC_POSITIONS card
# into a CIF on stdout.
#
#   $1  source file
#   $2  data_ name for the CIF block
#   $3  one line of provenance, printed as a comment
#   $4  alat in bohr, or empty - only consulted when a card says bare `alat`
#
# Units handled: CELL_PARAMETERS angstrom / bohr / alat / alat=<bohr>, and
# ATOMIC_POSITIONS crystal / angstrom / bohr / alat. Anything in a length unit
# has to be turned into fractional coordinates, which means inverting the
# lattice - done below rather than assumed away, because an input written for
# some other workflow is exactly the case this has to survive.
cif_emit() {
    local src="$1" dataname="$2" provenance="$3" alat_bohr="${4:-}"

    awk -v dataname="$dataname" \
        -v provenance="$provenance" \
        -v alat_bohr="$alat_bohr" \
        -v b2a="$CIF_BOHR_TO_ANG" '
    function lower(s) { return tolower(s) }
    function len3(x, y, z) { return sqrt(x*x + y*y + z*z) }
    function angle(x1,y1,z1, x2,y2,z2,   c) {
        c = (x1*x2 + y1*y2 + z1*z2) / (len3(x1,y1,z1) * len3(x2,y2,z2))
        if (c >  1) c =  1
        if (c < -1) c = -1
        return atan2(sqrt(1 - c*c), c) * 57.29577951308232
    }

    # Scale factor that turns this card unit into angstrom. -1 = unusable.
    function unit_scale(header,   h, v) {
        h = lower(header)
        if (h ~ /bohr/)      return b2a + 0
        if (h ~ /angstrom/)  return 1
        if (h ~ /alat/) {
            # alat= <number>, in bohr, as pw.x prints it in the output.
            if (h ~ /alat[[:space:]]*=/) {
                v = h
                sub(/.*alat[[:space:]]*=[[:space:]]*/, "", v)
                sub(/[^0-9.eEdD+-].*$/, "", v)
                if (v + 0 > 0) return (v + 0) * (b2a + 0)
            }
            if (alat_bohr + 0 > 0) return (alat_bohr + 0) * (b2a + 0)
            return -1
        }
        # No unit word at all. pw.x treats a bare CELL_PARAMETERS as alat,
        # which without an alat to multiply by is not something to guess at.
        return -1
    }

    /^[[:space:]]*CELL_PARAMETERS/ {
        cell_scale = unit_scale($0)
        cell_header = $0
        getline; a1 = $1; a2 = $2; a3 = $3
        getline; b1 = $1; b2v = $2; b3 = $3
        getline; c1 = $1; c2 = $2; c3 = $3
        have_cell = 1
        next
    }

    /^[[:space:]]*ATOMIC_POSITIONS/ {
        pos_header = $0
        pos_unit = lower($0)
        in_pos = 1
        next
    }

    in_pos && (NF == 0 || $0 ~ /^[[:space:]]*(End final coordinates|CELL_PARAMETERS|K_POINTS|ATOMIC_SPECIES|HUBBARD|OCCUPATIONS|CONSTRAINTS)/) {
        in_pos = 0
        next
    }

    # symbol x y z [if_pos flags], which are ignored.
    in_pos && NF >= 4 {
        n++
        label[n] = $1
        px[n] = $2 + 0; py[n] = $3 + 0; pz[n] = $4 + 0
        next
    }

    END {
        if (!have_cell) {
            print "CIF_ERROR no CELL_PARAMETERS card" > "/dev/stderr"
            exit 1
        }
        if (n == 0) {
            print "CIF_ERROR no ATOMIC_POSITIONS card" > "/dev/stderr"
            exit 1
        }
        if (cell_scale < 0) {
            print "CIF_ERROR cannot read the unit of: " cell_header > "/dev/stderr"
            exit 1
        }
        if (pos_unit ~ /crystal_sg/) {
            print "CIF_ERROR ATOMIC_POSITIONS crystal_sg is symmetry-generated;" \
                  " this writes P 1 and does not expand symmetry" > "/dev/stderr"
            exit 1
        }

        # Lattice in angstrom.
        a1 *= cell_scale; a2 *= cell_scale; a3 *= cell_scale
        b1 *= cell_scale; b2v *= cell_scale; b3 *= cell_scale
        c1 *= cell_scale; c2 *= cell_scale; c3 *= cell_scale

        la = len3(a1,a2,a3); lb = len3(b1,b2v,b3); lc = len3(c1,c2,c3)
        alpha = angle(b1,b2v,b3, c1,c2,c3)
        beta  = angle(a1,a2,a3, c1,c2,c3)
        gamma = angle(a1,a2,a3, b1,b2v,b3)

        # Positions to fractional.
        if (pos_unit ~ /crystal/) {
            for (i = 1; i <= n; i++) { fx[i] = px[i]; fy[i] = py[i]; fz[i] = pz[i] }
        } else {
            pscale = unit_scale(pos_header)
            # A bare ATOMIC_POSITIONS means alat to pw.x, same as the cell.
            if (pscale < 0 && pos_unit !~ /bohr|angstrom|alat/) pscale = cell_scale
            if (pscale < 0) {
                print "CIF_ERROR cannot read the unit of: " pos_header > "/dev/stderr"
                exit 1
            }

            # Cartesian (angstrom) -> fractional needs the inverse of the
            # lattice matrix whose ROWS are the three vectors.
            det = a1*(b2v*c3 - b3*c2) - a2*(b1*c3 - b3*c1) + a3*(b1*c2 - b2v*c1)
            if (det == 0) {
                print "CIF_ERROR the three lattice vectors are coplanar" > "/dev/stderr"
                exit 1
            }

            # Inverse of the transpose, i.e. what multiplies a cartesian column
            # vector to give fractional coordinates.
            m11 =  (b2v*c3 - b3*c2) / det
            m12 = -(a2*c3  - a3*c2) / det
            m13 =  (a2*b3  - a3*b2v) / det
            m21 = -(b1*c3  - b3*c1) / det
            m22 =  (a1*c3  - a3*c1) / det
            m23 = -(a1*b3  - a3*b1) / det
            m31 =  (b1*c2  - b2v*c1) / det
            m32 = -(a1*c2  - a2*c1) / det
            m33 =  (a1*b2v - a2*b1) / det

            for (i = 1; i <= n; i++) {
                X = px[i] * pscale; Y = py[i] * pscale; Z = pz[i] * pscale
                fx[i] = m11*X + m21*Y + m31*Z
                fy[i] = m12*X + m22*Y + m32*Z
                fz[i] = m13*X + m23*Y + m33*Z
            }
        }

        # Element symbol from the species label: QE writes Mo, Mo1, S_up, ...
        # Everything from the first digit or underscore on is a tag, not part
        # of the element.
        for (i = 1; i <= n; i++) {
            sym = label[i]
            sub(/[0-9_].*$/, "", sym)
            symbol[i] = sym
            count[sym]++
            if (!(sym in seen)) { seen[sym] = 1; order[++nsym] = sym }
        }

        formula = ""
        for (i = 1; i <= nsym; i++)
            formula = formula (i > 1 ? " " : "") order[i] count[order[i]]

        printf "# %s\n", provenance
        printf "# Written by qe.sh (QE_automation). Symmetry is P 1 by choice:\n"
        printf "# the space group is not guessed from relaxed coordinates.\n"
        printf "data_%s\n", dataname
        printf "_audit_creation_method           %s\n", "\047QE_automation qe.sh\047"
        printf "_chemical_formula_sum            \047%s\047\n", formula
        printf "_cell_length_a                   %.8f\n", la
        printf "_cell_length_b                   %.8f\n", lb
        printf "_cell_length_c                   %.8f\n", lc
        printf "_cell_angle_alpha                %.6f\n", alpha
        printf "_cell_angle_beta                 %.6f\n", beta
        printf "_cell_angle_gamma                %.6f\n", gamma
        printf "_symmetry_space_group_name_H-M   \047P 1\047\n"
        printf "_symmetry_Int_Tables_number      1\n"
        printf "loop_\n_symmetry_equiv_pos_as_xyz\n  \047x, y, z\047\n"
        printf "loop_\n"
        printf "_atom_site_label\n_atom_site_type_symbol\n"
        printf "_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\n"
        printf "_atom_site_occupancy\n"

        for (i = 1; i <= n; i++) {
            idx[symbol[i]]++
            printf "%-8s %-4s %12.8f %12.8f %12.8f  1.0000\n",
                   symbol[i] idx[symbol[i]], symbol[i], fx[i], fy[i], fz[i]
        }
    }
    ' "$src"
}

# One CIF, reporting rather than aborting when the source cannot be read: a
# structure file that is not there yet is a normal state, not a failure.
cif_write() {
    local src="$1" dest="$2" dataname="$3" provenance="$4" alat_bohr="$5"
    local tmp err

    tmp="$(mktemp "${dest}.XXXXXX")"

    if err="$(cif_emit "$src" "$dataname" "$provenance" "$alat_bohr" 2>&1 >"$tmp")"; then
        mv -f "$tmp" "$dest"
        echo "  wrote $(basename "$dest")  ($(grep -c '^[A-Z]' "$dest" || true) atoms)"
        return 0
    fi

    rm -f "$tmp"
    echo "  skipped $(basename "$dest"): ${err#CIF_ERROR }"
    return 1
}

step_cif() {
    require_cache

    # celldm(1) is in bohr, A in angstrom. Only consulted when a card is
    # written in alat and does not carry the number with it.
    local alat_bohr
    alat_bohr="$(get_param 'celldm\(1\)')"
    if [[ -z "$alat_bohr" ]]; then
        local a_ang
        a_ang="$(get_param A)"
        [[ -n "$a_ang" ]] && alat_bohr="$(awk -v a="$a_ang" -v b="$CIF_BOHR_TO_ANG" \
            'BEGIN { printf "%.10f", a / b }')"
    fi

    cif_write "$RELAX_IN" "$INPUT_DIR/${CASE_NAME}_initial.cif" \
        "${CASE_NAME}_initial" \
        "Geometry as written in $(basename "$RELAX_IN") - before relaxation." \
        "$alat_bohr" || true

    # The relaxed half needs step_extract to have run. Saying so beats failing:
    # `qe.sh cif` on a case whose relax has not finished should still give you
    # the starting structure.
    if [[ -f "$STRUCTURE_FILE" ]]; then
        cif_write "$STRUCTURE_FILE" "$INPUT_DIR/${CASE_NAME}_relaxed.cif" \
            "${CASE_NAME}_relaxed" \
            "Relaxed geometry from $(basename "$STRUCTURE_FILE") (via $(basename "$RELAX_OUT"))." \
            "$alat_bohr" || true
    else
        echo "  no $(basename "$STRUCTURE_FILE") yet, so only the initial structure"
        echo "  was written. Run the extract step once the relax has finished."
    fi

    return 0
}
