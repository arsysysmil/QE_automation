#!/bin/bash
# Writing <case>_band.path from the lattice the input actually describes.
#
# Sourced by qe.sh. Not executable on its own.

# Why this is not the old "apply template/band.path to everything" bug coming
# back: that one applied a Gamma-M-K-Gamma path unconditionally and said
# nothing, so a cubic material got a hexagonal path and produced a plausible
# looking, meaningless band structure. Here the lattice is *measured* from
# CELL_PARAMETERS, the classification and the numbers behind it are printed,
# and a cell that does not classify is refused rather than given a default.
#
# It still writes a file you own: edit <case>_band.path afterwards and the
# band step uses your version. init never overwrites without being asked.

# Lattice vectors -> a, b, c, alpha, beta, gamma -> a Bravais class.
# Ratios and angles only, so the unit of the CELL_PARAMETERS card does not
# matter (angstrom, bohr or alat all classify the same).
classify_lattice() {
    local relax_in="$1"

    awk '
    function len(x, y, z) { return sqrt(x*x + y*y + z*z) }
    function ang(x1,y1,z1, x2,y2,z2,   c) {
        c = (x1*x2 + y1*y2 + z1*z2) / (len(x1,y1,z1) * len(x2,y2,z2))
        if (c >  1) c =  1
        if (c < -1) c = -1
        return atan2(sqrt(1 - c*c), c) * 57.29577951308232
    }
    function near(u, v, tol) { return (u - v <= tol && v - u <= tol) }

    /^[[:space:]]*CELL_PARAMETERS/ {
        getline; ax=$1; ay=$2; az=$3
        getline; bx=$1; by=$2; bz=$3
        getline; cx=$1; cy=$2; cz=$3

        a = len(ax,ay,az); b = len(bx,by,bz); c = len(cx,cy,cz)
        al = ang(bx,by,bz, cx,cy,cz)
        be = ang(ax,ay,az, cx,cy,cz)
        ga = ang(ax,ay,az, bx,by,bz)

        # 0.1% on lengths, 0.5 degree on angles. A relaxed cell is never
        # exact so some slack is needed, but 1% was far too loose: BaTiO3 at
        # a=3.99 b=4.01 c=4.03 - an orthorhombic ferroelectric whose whole
        # point is that distortion - came out classified as simple cubic.
        # The distortion that matters physically is often ~1%.
        ltol = 0.001 * (a > b ? (a > c ? a : c) : (b > c ? b : c))

        ab = near(a, b, ltol); bc = near(b, c, ltol); ac = near(a, c, ltol)
        a90 = near(al, 90, 0.5); b90 = near(be, 90, 0.5); g90 = near(ga, 90, 0.5)

        type = "unknown"

        if (ab && a90 && b90 && (near(ga, 120, 0.5) || near(ga, 60, 0.5))) {
            # Hexagonal, in either of the two settings QE inputs use. They are
            # the same lattice but NOT the same reciprocal basis, so K is at
            # (1/3,1/3,0) for gamma=120 and (2/3,1/3,0) for gamma=60. Getting
            # this wrong puts the label "K" on a point inside the zone - see
            # the note in MAINTENANCE.md.
            #
            # A slab is the same lattice with vacuum along c, and wants a path
            # with no k_z: sampling k_z of a vacuum gap is meaningless work.
            if (near(ga, 60, 0.5))
                type = (c / a > 2.0) ? "hex60_2d" : "hex60"
            else
                type = (c / a > 2.0) ? "hex120_2d" : "hex120"
        } else if (ab && bc && a90 && b90 && g90) {
            type = "cub"
        } else if (ab && bc && near(al, 60, 0.5) && near(be, 60, 0.5) && near(ga, 60, 0.5)) {
            type = "fcc"
        } else if (ab && bc && near(al, 109.4712, 0.5) && near(be, 109.4712, 0.5) && near(ga, 109.4712, 0.5)) {
            type = "bcc"
        } else if (ab && !bc && a90 && b90 && g90) {
            type = "tet"
        } else if (!ab && !bc && !ac && a90 && b90 && g90) {
            type = "orc"
        }

        printf "%s %.6f %.6f %.6f %.4f %.4f %.4f\n", type, a, b, c, al, be, ga
        exit
    }
    ' "$relax_in"
}

# The high-symmetry path per class, in crystal_b (fractional reciprocal)
# coordinates. Connected paths only, so the file stays one readable block.
# Standard Setyawan-Curtarolo points.
band_path_for() {
    case "$1" in
        hex120_2d) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! M
0.3333333333  0.3333333333  0.0000000000  __BAND_POINTS__   ! K
0.0000000000  0.0000000000  0.0000000000   1                ! G
PATH
        ;;
        hex60_2d) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! M
0.6666666667  0.3333333333  0.0000000000  __BAND_POINTS__   ! K
0.0000000000  0.0000000000  0.0000000000   1                ! G
PATH
        ;;
        hex120) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! M
0.3333333333  0.3333333333  0.0000000000  __BAND_POINTS__   ! K
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.0000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! A
0.5000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! L
0.3333333333  0.3333333333  0.5000000000  __BAND_POINTS__   ! H
0.0000000000  0.0000000000  0.5000000000   1                ! A
PATH
        ;;
        hex60) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! M
0.6666666667  0.3333333333  0.0000000000  __BAND_POINTS__   ! K
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.0000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! A
0.5000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! L
0.6666666667  0.3333333333  0.5000000000  __BAND_POINTS__   ! H
0.0000000000  0.0000000000  0.5000000000   1                ! A
PATH
        ;;
        cub) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.0000000000  0.5000000000  0.0000000000  __BAND_POINTS__   ! X
0.5000000000  0.5000000000  0.0000000000  __BAND_POINTS__   ! M
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000  0.5000000000  0.5000000000  __BAND_POINTS__   ! R
0.0000000000  0.5000000000  0.0000000000   1                ! X
PATH
        ;;
        fcc) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! X
0.5000000000  0.2500000000  0.7500000000  __BAND_POINTS__   ! W
0.3750000000  0.3750000000  0.7500000000  __BAND_POINTS__   ! K
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000  0.5000000000  0.5000000000  __BAND_POINTS__   ! L
0.6250000000  0.2500000000  0.6250000000  __BAND_POINTS__   ! U
0.5000000000  0.2500000000  0.7500000000  __BAND_POINTS__   ! W
0.5000000000  0.5000000000  0.5000000000  __BAND_POINTS__   ! L
0.3750000000  0.3750000000  0.7500000000   1                ! K
PATH
        ;;
        bcc) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000 -0.5000000000  0.5000000000  __BAND_POINTS__   ! H
0.0000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! N
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.2500000000  0.2500000000  0.2500000000  __BAND_POINTS__   ! P
0.5000000000 -0.5000000000  0.5000000000   1                ! H
PATH
        ;;
        tet) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.0000000000  0.5000000000  0.0000000000  __BAND_POINTS__   ! X
0.5000000000  0.5000000000  0.0000000000  __BAND_POINTS__   ! M
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.0000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! Z
0.0000000000  0.5000000000  0.5000000000  __BAND_POINTS__   ! R
0.5000000000  0.5000000000  0.5000000000  __BAND_POINTS__   ! A
0.0000000000  0.0000000000  0.5000000000   1                ! Z
PATH
        ;;
        orc) cat <<'PATH'
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.5000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! X
0.5000000000  0.5000000000  0.0000000000  __BAND_POINTS__   ! S
0.0000000000  0.5000000000  0.0000000000  __BAND_POINTS__   ! Y
0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
0.0000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! Z
0.5000000000  0.0000000000  0.5000000000  __BAND_POINTS__   ! U
0.5000000000  0.5000000000  0.5000000000  __BAND_POINTS__   ! R
0.0000000000  0.5000000000  0.5000000000  __BAND_POINTS__   ! T
0.0000000000  0.0000000000  0.5000000000   1                ! Z
PATH
        ;;
        *) return 1 ;;
    esac
}

lattice_description() {
    case "$1" in
        hex60_2d)  echo "hexagonal slab, gamma=60 setting  (2D: path stays at k_z = 0)" ;;
        hex120_2d) echo "hexagonal slab, gamma=120 setting (2D: path stays at k_z = 0)" ;;
        hex60)     echo "hexagonal 3D, gamma=60 setting" ;;
        hex120)    echo "hexagonal 3D, gamma=120 setting" ;;
        cub)   echo "simple cubic" ;;
        fcc)   echo "face-centred cubic" ;;
        bcc)   echo "body-centred cubic" ;;
        tet)   echo "tetragonal" ;;
        orc)   echo "orthorhombic" ;;
        *)     echo "unclassified" ;;
    esac
}

step_init() {
    local measured type a b c al be ga npoints

    measured="$(classify_lattice "$RELAX_IN")"

    if [[ -z "$measured" ]]; then
        echo "ERROR: no CELL_PARAMETERS card in $RELAX_IN."
        echo "       This pipeline needs ibrav = 0 with the three lattice"
        echo "       vectors written out; there is nothing to classify."
        exit 1
    fi

    read -r type a b c al be ga <<< "$measured"

    echo "Lattice measured from $(basename "$RELAX_IN"):"
    printf '  a = %.4f   b = %.4f   c = %.4f\n' "$a" "$b" "$c"
    printf '  alpha = %.2f   beta = %.2f   gamma = %.2f\n' "$al" "$be" "$ga"
    echo "  -> $(lattice_description "$type")"
    echo ""

    # A band structure along a path needs a dispersion to plot. A gamma-only
    # cell has one k-point, so there is nothing to disperse - writing a path
    # for it would be a file that only produces a nonsense figure.
    if grep -iE "^[[:space:]]*K_POINTS" "$RELAX_IN" | head -1 | grep -qi gamma; then
        echo "NOTE: this case is gamma-only (K_POINTS gamma), typical of an"
        echo "      isolated molecule. A band structure along a k-path is not"
        echo "      meaningful for it - the DOS route is what you want. Writing"
        echo "      the path anyway, but the band step will not tell you much."
        echo ""
    fi

    if [[ "$type" == "unknown" ]]; then
        echo "ERROR: this cell does not match any lattice with a built-in path."
        echo "       Rather than guess - which is how a wrong band structure gets"
        echo "       produced with no error at all - write the path yourself:"
        echo ""
        echo "         $BAND_PATH_FILE"
        echo ""
        echo "       Use K_POINTS crystal_b, one high-symmetry point per line,"
        echo "       with __BAND_POINTS__ where the per-segment count belongs."
        echo "       $ROOT_DIR/template/band.path.hex_gamma60_example is the shape."
        exit 1
    fi

    if [[ -f "$BAND_PATH_FILE" ]]; then
        echo "ERROR: $BAND_PATH_FILE already exists."
        echo "       Not overwriting - it may be a path you wrote by hand."
        echo "       Delete it first if you want it regenerated."
        exit 1
    fi

    npoints="$(grep -c '__BAND_POINTS__' <<< "$(band_path_for "$type")")"

    {
        printf 'K_POINTS crystal_b\n'
        printf '%s\n' "$(( npoints + 1 ))"
        band_path_for "$type"
    } > "$BAND_PATH_FILE"

    echo "Band path written: $BAND_PATH_FILE"
    sed 's/^/  /' "$BAND_PATH_FILE"
    echo ""
    echo "Check the path suits what you want to show before running - it is a"
    echo "standard path for this lattice, not necessarily the one your figure"
    echo "needs. Edit the file and the band step uses your version."
}
