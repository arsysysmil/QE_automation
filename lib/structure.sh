#!/bin/bash
# Pulling the relaxed geometry out of the relax output.
#
# Sourced by qe.sh. Not executable on its own.

#############################
# Did the relaxation actually converge?
#############################
#
# pw.x prints `JOB DONE.` whether or not the geometry converged, and
# check_done() looks for nothing else. A BFGS run that hits `nstep` prints
#
#     The maximum number of steps has been reached.
#     End of BFGS Geometry Optimization
#
# and then exits cleanly: from the program's point of view it was asked for 50
# steps and gave 50 steps. step_extract() then takes the LAST ATOMIC_POSITIONS
# block in the file - the 50th BFGS step, still carrying forces above the
# threshold - and labels it "relaxed positions". Every later stage runs on a
# structure that is not a stationary point, and nothing says so.
#
# What that costs, in the terms this project is used for: an adsorption energy
# E_ads = E(slab+gas) - E(slab) - E(gas) computed from a geometry above the
# minimum is too weak, sometimes enough to move a case from chemisorption to
# physisorption; the adsorption distance and charge transfer that feed a
# descriptor table are simply wrong; and a band structure computed there
# belongs to a structure that does not exist.
#
# So: `bfgs converged` is required, not inferred. The output says it in as many
# words, for both `relax` and `vc-relax`.

RELAX_CONVERGED_LINE=""
RELAX_MAXSTEPS=0
RELAX_FINAL_FORCE=""
RELAX_FORCE_THRESHOLD=""
RELAX_MAX_FORCE=""
RELAX_CRITERIA=""

relax_convergence_scan() {
    local out="$1"

    RELAX_CONVERGED_LINE=""
    RELAX_MAXSTEPS=0
    RELAX_FINAL_FORCE=""
    RELAX_FORCE_THRESHOLD=""
    RELAX_MAX_FORCE=""
    RELAX_CRITERIA=""

    [[ -f "$out" ]] || return 1

    RELAX_CONVERGED_LINE="$(grep -m1 'bfgs converged' "$out" \
        | sed -E 's/^[[:space:]]*//; s/[[:space:]]+$//' || true)"

    grep -q 'maximum number of steps has been reached' "$out" && RELAX_MAXSTEPS=1

    RELAX_FORCE_THRESHOLD="$(grep -m1 'force convergence thresh' "$out" \
        | awk '{print $NF}' || true)"

    RELAX_CRITERIA="$(grep -m1 '(criteria:' "$out" \
        | sed -E 's/^[[:space:]]*//; s/[[:space:]]+$//' || true)"

    # The last one in the file. For a plain relax that is the converged step.
    # For a vc-relax it is the final scf QE runs at the relaxed cell with
    # recalculated G-vectors - see relax_final_force_note().
    RELAX_FINAL_FORCE="$(grep 'Total force' "$out" | tail -1 | awk '{print $4}' || true)"

    # The largest single force COMPONENT of the last force block.
    #
    # Not `Total force`, which is the norm of the whole 3N-vector. QE's
    # criterion is per component - "the convergence criterion is satisfied when
    # all components of all forces are smaller than forc_conv_thr" - and the
    # norm is larger than any component by roughly sqrt(3N). Comparing the norm
    # against forc_conv_thr therefore reports every many-atom cell as
    # unconverged: phosphorene, whose four atoms all sit at components of
    # ~0.0007 against a 1.0E-03 threshold, has a norm of 0.002004 and was
    # flagged by exactly that mistake before this was written.
    # Stops at the force DECOMPOSITION, which QE prints between the force
    # listing and the `Total force` line:
    #
    #     Forces acting on atoms (cartesian axes, Ry/au):
    #     atom 1 type 1  force = ...          <- these
    #     The non-local contrib.  to forces
    #     atom 1 type 1  force = ...          <- NOT these
    #     The core correction contribution to forces
    #     atom 1 type 1  force = ...          <- nor these
    #     Total force = ...
    #
    # Those terms are individually huge and mostly cancel. Reading them as if
    # they were the force on an atom reported 37.07 Ry/au for a production
    # MoS2+NO2 run whose actual largest component was 0.0018 - and on a
    # converged run it would have raised a Pulay warning that was pure
    # arithmetic. The laptop's test outputs happen not to print the
    # decomposition, which is why it survived until it met real cluster data.
    #
    # Any "... to forces" header ends the block; the main header does not
    # contain that phrase, so it is not caught by its own rule.
    RELAX_MAX_FORCE="$(awk '
        /Forces acting on atoms/ { maxf = 0; have = 1; inblock = 1; next }
        /to forces/              { inblock = 0; next }
        /Total force/            { inblock = 0 }
        inblock && /^[[:space:]]*atom[[:space:]]+[0-9]+[[:space:]]+type/ {
            for (i = NF - 2; i <= NF; i++) {
                v = ($i < 0 ? -$i : $i)
                if (v > maxf) maxf = v
            }
        }
        END { if (have) printf "%.8f", maxf }
    ' "$out" || true)"

    return 0
}

# A vc-relax converges against the basis set of the cell it *started* from.
# When the cell then changes, QE re-runs one scf with the G-vectors of the
# final cell and says so:
#
#     Final scf calculation at the relaxed structure.
#     The G-vectors are recalculated for the final unit cell
#     Results may differ from those at the preceding step.
#
# If the force from that scf is above the threshold the BFGS was judged
# against, the structure is converged in the old basis and not in the correct
# one - Pulay stress. The standard remedy is to run vc-relax again starting
# from the final structure until the cell stops moving, or to raise ecutwfc
# until the two agree.
#
# A warning, not an error: the run did converge by the criterion it was given,
# the effect is a known property of plane-wave vc-relax rather than a fault in
# this input, and how much of it matters depends on what the number is for.
relax_final_force_note() {
    # The calculation is passed in rather than read from CALCULATION, because
    # step_check() deliberately runs without a sourced cache and resolves it
    # from the input file instead.
    local calc="${1:-${CALCULATION:-}}"

    [[ -n "$RELAX_MAX_FORCE" && -n "$RELAX_FORCE_THRESHOLD" ]] || return 0

    awk -v f="$RELAX_MAX_FORCE" -v t="$RELAX_FORCE_THRESHOLD" \
        'BEGIN { exit !(f > t) }' || return 0

    echo "  WARNING: the largest force component in the last block of this output"
    echo "           is $RELAX_MAX_FORCE Ry/au, above the ${RELAX_FORCE_THRESHOLD} Ry/au it was judged against."
    if [[ "${calc,,}" == vc-* ]]; then
        echo "           This is the final scf QE runs at the relaxed cell, where the"
        echo "           G-vectors are recalculated - so the structure is converged in"
        echo "           the basis it started with and not in the correct one (Pulay"
        echo "           stress). Re-run vc-relax from the final structure until the"
        echo "           cell stops moving, or raise ecutwfc until the two agree."
    else
        echo "           Check what produced it before using this geometry."
    fi
}

# Refuses a geometry that was never optimised. Called from step_relax (so the
# pipeline stops at 2/12 rather than after the scf) and from step_extract (so
# it also applies to a relax run outside this workflow - a hand-written run.sh
# on the cluster, or output copied down from one).
assert_relax_converged() {
    local out="$1"

    # Nothing to converge in an scf/nscf input. SETUP.md warns separately that
    # such an input takes its positions straight from the input file.
    local calc="${CALCULATION:-}"
    [[ "${calc,,}" == *relax* ]] || return 0

    relax_convergence_scan "$out" || return 0

    if [[ -n "$RELAX_CONVERGED_LINE" ]]; then
        echo "  converged: $RELAX_CONVERGED_LINE"
        relax_final_force_note "$calc"
        return 0
    fi

    local verdict="ERROR"
    (( ${REQUIRE_RELAX_CONVERGED:-1} )) || verdict="WARNING"

    echo ""
    echo "$verdict: the relaxation in $(basename "$out") never converged."
    echo ""

    if (( RELAX_MAXSTEPS )); then
        echo "  QE reported: The maximum number of steps has been reached."
        echo "  BFGS ran out of ionic steps (nstep, default 50) before the forces"
        echo "  came under the threshold. pw.x still printed JOB DONE., because it"
        echo "  did what it was asked - it is the geometry that is unfinished."
    else
        echo "  No 'bfgs converged' line, and no 'maximum number of steps' either."
        echo "  The run ended before BFGS reported anything: killed part-way, or a"
        echo "  form of ionic dynamics this check does not recognise."
    fi

    echo ""
    [[ -n "$RELAX_CRITERIA" ]]    && echo "  $RELAX_CRITERIA"
    [[ -n "$RELAX_MAX_FORCE" ]] && \
        echo "  largest remaining force component: $RELAX_MAX_FORCE Ry/au (threshold ${RELAX_FORCE_THRESHOLD:-?})"
    echo ""
    echo "  Using it anyway would mean an scf, a band structure and a DOS computed"
    echo "  on a structure that is not a minimum - and an adsorption energy or"
    echo "  bond length taken from it would be wrong with nothing to show for it."
    echo ""
    echo "  What usually causes this, in rough order for adsorption work:"
    echo "    - a flat energy surface: a physisorbed molecule slides or rotates"
    echo "      almost for free, so the forces never settle. Give it more nstep,"
    echo "      or start it closer to the site you mean."
    echo "    - nstep too small for a slab plus a molecule finding its orientation."
    echo "    - conv_thr too loose: forces are a derivative, so scf noise is"
    echo "      amplified in them and BFGS ends up chasing it. 1.0d-8 or tighter."
    echo "    - degauss too large, smearing the occupations and the forces with it."
    echo "    - a spin-polarised system flipping between spin states between ionic"
    echo "      steps, so the forces jump rather than shrink."
    echo "    - a starting geometry with atoms too close (look for 'history reset')."
    echo ""
    echo "  Restart from the last geometry in this output rather than from the"
    echo "  beginning: copy its final ATOMIC_POSITIONS into the input and re-run."
    echo ""

    if [[ "$verdict" == "WARNING" ]]; then
        echo "  REQUIRE_RELAX_CONVERGED=0 in config.sh, so this is a warning and the"
        echo "  pipeline continues. Everything after this point is computed on the"
        echo "  unconverged geometry above."
        return 0
    fi

    echo "  If you know why and want to proceed anyway, set"
    echo "  REQUIRE_RELAX_CONVERGED=0 in config.sh. It is 1 for a reason."

    exit 1
}

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

    # Before anything is read out of it. A geometry that never reached a
    # minimum is not a structure this pipeline should hand to the scf, and
    # `extract` is the gate that also covers a relax run outside this workflow.
    assert_relax_converged "$RELAX_OUT"

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

        if [[ "${CALCULATION:-}" == [Vv][Cc]-* ]]; then
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

