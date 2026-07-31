#!/bin/bash
# Work function of a slab.
#
# Sourced by qe.sh. Not executable on its own.
#
#     Phi = V_vacuum - E_Fermi
#
# V_vacuum is the plateau the planar-averaged electrostatic potential reaches
# in the vacuum gap. Getting it needs two post-processing runs over the charge
# density the SCF already produced - no new SCF:
#
#     pp.x        plot_num = 11 (bare + Hartree potential) -> a 3D field
#     average.x   planar average of that field along the slab normal -> V(z)
#
# Measured on phosphorene, 6 ranks: pp.x 2.7 s, average.x 2.2 s. Against a
# pipeline that takes minutes to hours, this step is free.
#
# Conventions follow the MoS2 gas-sensor runs that already exist outside this
# workflow (mos2/work_function/), so numbers from the two are comparable:
# plot_num=11, planar average along axis 3, potential in Ry converted with
# 13.60569, and E_Fermi taken from the SCF. See §1.12 in MAINTENANCE.md for
# why the SCF and not the NSCF here, which is the opposite of what step_plot
# does and is deliberate.

RY_TO_EV='13.60569'

# Is this a slab, and where is the vacuum?
#
# Reuses the c/a > 2 test that lib/init.sh applies to pick a 2D band path. A
# bulk cell has no vacuum, so it has no work function, and producing a number
# for one would be worse than producing nothing.
#
# Sets WF_C_ANG and the vacuum bounds WF_VAC_LO_ANG / WF_VAC_HI_ANG (angstrom;
# the upper bound may exceed c when the vacuum wraps across the cell edge).
wf_slab_geometry() {
    local structure="$1"

    WF_C_ANG=""; WF_VAC_LO_ANG=""; WF_VAC_HI_ANG=""

    # The cell as written by step_extract: three CELL_PARAMETERS rows in
    # angstrom. Only c matters, and only its z component - every lattice this
    # workflow accepts has c along z when it has a vacuum at all.
    read -r WF_A_ANG WF_C_ANG < <(awk '
        /CELL_PARAMETERS/ { n = 0; incell = 1; next }
        incell && NF >= 3 {
            n++
            if (n == 1) a = sqrt($1*$1 + $2*$2 + $3*$3)
            if (n == 3) { c = sqrt($1*$1 + $2*$2 + $3*$3); print a, c; exit }
        }
    ' "$structure")

    [[ -n "$WF_C_ANG" ]] || return 1

    # Atom positions are crystal coordinates in structure.in. Fold into [0,1)
    # first: a slab written centred on z=0 has atoms at both 0.04 and 0.95,
    # and taking the raw min/max would call that a slab filling the whole cell.
    read -r WF_VAC_LO_ANG WF_VAC_HI_ANG < <(awk -v c="$WF_C_ANG" '
        /ATOMIC_POSITIONS/ { inpos = 1; next }
        # An atom line is "<symbol> x y z". Test that the coordinates are
        # numbers rather than that the symbol is not a word - the species
        # symbol IS a word, which is what an earlier version got wrong and
        # which made every case look like it had no atoms at all.
        inpos && NF >= 4 && $2 ~ /^-?[0-9.]+([eEdD][-+]?[0-9]+)?$/ {
            z = $4 - int($4); if (z < 0) z += 1
            zs[n++] = z
        }
        END {
            if (n == 0) exit
            # Find the largest gap between consecutive folded z values: that
            # gap is the vacuum, and the slab is everything else.
            for (i = 0; i < n; i++)
                for (j = i+1; j < n; j++)
                    if (zs[j] < zs[i]) { t = zs[i]; zs[i] = zs[j]; zs[j] = t }
            best = -1
            for (i = 0; i < n; i++) {
                lo = zs[i]
                hi = (i == n-1) ? zs[0] + 1 : zs[i+1]
                if (hi - lo > best) { best = hi - lo; gap_lo = lo; gap_hi = hi }
            }
            # The VACUUM is that gap. gap_hi may exceed 1 when the vacuum
            # straddles the cell boundary (slab drawn in the middle of the
            # cell); the caller handles the wrap.
            printf "%.6f %.6f\n", gap_lo * c, gap_hi * c
        }
    ' "$structure")

    [[ -n "$WF_VAC_LO_ANG" ]] || return 1
    return 0
}

# Planar-averaged potential -> the vacuum plateau.
#
# avg.dat from average.x is three columns: z in bohr, planar average, and a
# macroscopic (window) average. Column 2 is the one wanted; the macroscopic
# average smooths over a window and is for bulk interface work, not this.
#
# Sets WF_VVAC_EV, WF_RIPPLE_EV, and for an asymmetric slab also
# WF_VVAC_LO_EV / WF_VVAC_HI_EV.
wf_vacuum_level() {
    local avg="$1" vlo="$2" vhi="$3"

    # vlo/vhi delimit the VACUUM, and vhi may exceed c when the vacuum wraps
    # across the cell edge. The plateau is read from the middle 50% of it:
    # near the surface the potential is still decaying, and at the cell edge a
    # dipole correction leaves a sawtooth discontinuity.
    read -r WF_VVAC_EV WF_RIPPLE_EV WF_VVAC_LO_EV WF_VVAC_HI_EV < <(awk \
        -v vlo="$vlo" -v vhi="$vhi" -v c="$WF_C_ANG" -v ry="$RY_TO_EV" '
        BEGIN {
            b = 0.529177210903
            span = vhi - vlo
            lo   = vlo + 0.25 * span
            hi   = vlo + 0.75 * span
            half = (lo + hi) / 2
        }
        !/^ *#/ && NF >= 2 {
            z = $1 * b                  # bohr -> angstrom
            v = $2 * ry                 # Ry   -> eV
            # avg.dat tabulates 0..c. Shift a point up by one cell when the
            # window runs past the edge, so a wrapped vacuum is still covered.
            if (z < vlo && z + c <= vhi) z += c
            if (z < lo || z > hi) next
            m++; sum += v; s2 += v * v
            if (z < half) { sl += v; ml++ } else { sh += v; mh++ }
        }
        END {
            if (m == 0) exit
            mean = sum / m
            var  = s2 / m - mean * mean
            printf "%.6f %.3e %.6f %.6f\n", mean, (var > 0 ? sqrt(var) : 0),
                   (ml ? sl/ml : mean), (mh ? sh/mh : mean)
        }
    ' "$avg")

    [[ -n "$WF_VVAC_EV" ]]
}

step_workfunction() {
    require_cache
    require_structure

    local pp_in="$INPUT_DIR/${CASE_NAME}_pp.in"
    local pp_out="$INPUT_DIR/${CASE_NAME}_pp.out"
    local avg_in="$INPUT_DIR/${CASE_NAME}_avg.in"
    local avg_out="$INPUT_DIR/${CASE_NAME}_avg.out"
    local filplot="${CASE_NAME}.pot"
    local profile="$INPUT_DIR/${CASE_NAME}_potential.dat"

    if ! wf_slab_geometry "$STRUCTURE_FILE"; then
        echo "  skipped: could not read the cell or the atom positions from"
        echo "  $(basename "$STRUCTURE_FILE"). Run the extract step first."
        return 0
    fi

    # A work function needs a vacuum to measure into. Bulk has none.
    local is_slab
    is_slab=$(awk -v a="$WF_A_ANG" -v c="$WF_C_ANG" 'BEGIN { print (c/a > 2.0) ? 1 : 0 }')
    if [[ "$is_slab" != "1" ]]; then
        printf '  skipped: c/a = %.2f, so this is a bulk cell, not a slab.\n' \
            "$(awk -v a="$WF_A_ANG" -v c="$WF_C_ANG" 'BEGIN{printf "%.4f", c/a}')"
        echo "  A work function is the energy to remove an electron to the vacuum,"
        echo "  and a bulk cell has no vacuum to remove it to. Nothing to compute."
        return 0
    fi

    load_modules

    if ! command -v "${PP%% *}" >/dev/null 2>&1 || ! command -v "${AVERAGE%% *}" >/dev/null 2>&1; then
        echo "  skipped: ${PP%% *} or ${AVERAGE%% *} is not on PATH."
        echo "  Both ship with Quantum ESPRESSO; this step needs no new SCF, so it"
        echo "  can be run later on a machine that has them:"
        echo "    qe.sh workfunction $INPUT_NAME"
        return 0
    fi

    # plot_num = 11 is V_bare + V_Hartree - the electrostatic potential an
    # electron sees, with the exchange-correlation part left out. That is the
    # convention the work function is defined against; plot_num = 1 would add
    # V_xc, which does not vanish in vacuum the way the reader expects.
    cat > "$pp_in" <<EOF
&INPUTPP
    prefix   = '$PREFIX'
    outdir   = '$OUTDIR'
    plot_num = 11
    filplot  = '$filplot'
/
EOF

    echo "Running pp.x (electrostatic potential)"
    (
        cd "$INPUT_DIR"
        $MPI $PP < "$(basename "$pp_in")" > "$(basename "$pp_out")"
    )
    check_done "$pp_out" "pp.x"

    # average.x reads a free-format list, not a namelist: file count, then a
    # filename and weight per file, then points along the axis, the axis, and
    # the macroscopic-average window.
    #
    # That last number must NOT be 0. It is the window length in bohr for the
    # *macroscopic* average (output column 3), and average.x aborts with
    # "Error in routine average (1): nmacro is too small" when the window
    # holds no grid points. The value itself does not matter here - column 2,
    # the planar average, is a plain in-plane mean and is independent of it -
    # so 1.0 bohr is used simply because it is valid.
    #
    # The existing MoS2 work-function inputs outside this workflow pass 0.0,
    # which is why their runner script treats average.x as optional and says
    # not to let it abort the pipeline: it was failing every time.
    cat > "$avg_in" <<EOF
1
$filplot
1.0
$WF_AVG_NPT
3
1.0
EOF

    echo "Running average.x (planar average along z)"
    (
        cd "$INPUT_DIR"
        $AVERAGE < "$(basename "$avg_in")" > "$(basename "$avg_out")" 2>&1
    ) || true

    if [[ ! -s "$INPUT_DIR/avg.dat" ]]; then
        echo "  ERROR: average.x produced no avg.dat."
        echo "  Its output:"
        sed 's/^/    /' "$avg_out" | tail -20
        return 0
    fi

    mv "$INPUT_DIR/avg.dat" "$profile"

    if ! wf_vacuum_level "$profile" "$WF_VAC_LO_ANG" "$WF_VAC_HI_ANG"; then
        echo "  ERROR: no points fell inside the vacuum window - cannot read a plateau."
        return 0
    fi

    # E_Fermi from the SCF, deliberately - see the header comment and §1.12.
    local ef ef_src="scf output"
    if ! ef="$(plot_fermi_from_out "$SCF_OUT")"; then
        echo "  skipped: no Fermi energy in $(basename "$SCF_OUT")."
        return 0
    fi

    local phi asym
    phi=$(awk -v v="$WF_VVAC_EV" -v e="$ef" 'BEGIN{printf "%.4f", v - e}')
    asym=$(awk -v a="$WF_VVAC_LO_EV" -v b="$WF_VVAC_HI_EV" 'BEGIN{printf "%.4f", (a>b?a-b:b-a)}')

    echo ""
    printf '  vacuum spans z = %.3f .. %.3f A  (cell c = %.3f A)\n' \
        "$WF_VAC_LO_ANG" "$WF_VAC_HI_ANG" "$WF_C_ANG"
    printf '  vacuum level   = %+.4f eV   (ripple %.1e eV)\n' "$WF_VVAC_EV" "$WF_RIPPLE_EV"
    printf '  E_Fermi        = %+.4f eV   (%s)\n' "$ef" "$ef_src"
    printf '  WORK FUNCTION  = %.4f eV\n' "$phi"
    echo "  profile        : $(basename "$profile")  (z in bohr, V in Ry)"

    # A flat plateau is the evidence that the vacuum gap is thick enough. A
    # ripple of order 1e-3 eV or more means the two surfaces still see each
    # other, and the number above is not converged with respect to c.
    if awk -v r="$WF_RIPPLE_EV" 'BEGIN{exit !(r > 1e-3)}'; then
        echo ""
        echo "  WARNING: the vacuum plateau is not flat (ripple ${WF_RIPPLE_EV} eV)."
        echo "           Usually this means the vacuum gap is too thin and the slab's"
        echo "           two surfaces still interact. Increase c and re-run."
    fi

    # Two different vacuum levels either side of the slab = a net dipole. With
    # tefield/dipfield on, QE compensates it and the sawtooth lands in the
    # vacuum; without them, the periodic images interact and BOTH numbers are
    # suspect. This is the case for a slab with an adsorbate on one face only.
    if awk -v d="$asym" 'BEGIN{exit !(d > 0.05)}'; then
        echo ""
        printf '  NOTE: the two sides of the vacuum differ by %.4f eV\n' "$asym"
        printf '        lower side %+.4f eV -> Phi = %.4f eV\n' \
            "$WF_VVAC_LO_EV" "$(awk -v v="$WF_VVAC_LO_EV" -v e="$ef" 'BEGIN{printf "%.4f", v-e}')"
        printf '        upper side %+.4f eV -> Phi = %.4f eV\n' \
            "$WF_VVAC_HI_EV" "$(awk -v v="$WF_VVAC_HI_EV" -v e="$ef" 'BEGIN{printf "%.4f", v-e}')"
        echo "        An asymmetric slab (adsorbate on one face) genuinely has two"
        if grep -qiE '^[^!]*dipfield *= *\.true\.' "$RELAX_IN"; then
            echo "        work functions, and dipfield is on, so both are meaningful."
        else
            echo "        work functions - but dipfield is NOT set in the input, so the"
            echo "        periodic images are still interacting and both are suspect."
            echo "        FIX: add tefield/dipfield/edir/emaxpos/eopreg to the relax input."
        fi
    fi

    return 0
}
