#!/bin/bash
# Turn the finished data files into figures.
#
# Sourced by qe.sh. Not executable on its own.
#
# Everything this step needs is already on disk when it runs:
#
#   <prefix>.bands.dat.gnu   bands.x  - blank-line separated blocks, one per band
#   <prefix>.dos             dos.x    - E, dos(E), int dos(E)  (+ a 4th column
#                                       when nspin=2: E, up, down, int)
#   <case>_bandsx.out        bands.x  - "high-symmetry point: ... x coordinate X",
#                                       the x positions the tick marks go at
#   <case>_band.in           gen-band - the "! G" comments, i.e. the tick labels
#   <case>_scf.out           scf      - the Fermi energy
#
# So plotting reads no wavefunctions and needs no MPI. It is safe to re-run on
# an old case, and safe to run on a laptop against data copied down from the
# cluster.
#
# This step is FAIL-SOFT: it returns success even when it cannot draw anything.
# It is the last step of an hours-long pipeline, and a missing matplotlib on a
# compute node is not a reason to mark a finished calculation as failed. The
# data is the deliverable; the picture is a convenience. Whatever went wrong is
# printed in full, so a silent failure is not possible - only a non-fatal one.

# Which engine to use, honouring PLOT_ENGINE from config.sh.
plot_pick_engine() {
    local want="${PLOT_ENGINE:-auto}"

    case "$want" in
        none)
            # Distinct from 'none' below: the user turned plotting off on
            # purpose, so there is nothing to advise them to install.
            printf 'off'
            return 0
            ;;
        python|gnuplot)
            printf '%s' "$want"
            return 0
            ;;
        auto) ;;
        *)
            echo "  warning: PLOT_ENGINE='$want' in config.sh is not one of" >&2
            echo "           auto / python / gnuplot / none - treating it as auto" >&2
            ;;
    esac

    if python3 -c 'import matplotlib' >/dev/null 2>&1; then
        printf 'python'
    elif command -v gnuplot >/dev/null 2>&1; then
        printf 'gnuplot'
    else
        printf 'none'
    fi
}

# Pull a Fermi level (or, for occupations='fixed', the band edge QE reports
# instead) out of one pw.x output. Prints nothing and fails if neither is there.
plot_fermi_from_out() {
    local out="$1" line

    [[ -f "$out" ]] || return 1

    line="$(grep -E 'the Fermi energy is' "$out" | tail -1 || true)"
    if [[ -n "$line" ]]; then
        awk '{print $(NF-1)}' <<<"$line"
        return 0
    fi

    # occupations='fixed': QE reports band edges instead of a Fermi level.
    # The valence band maximum is the conventional zero for these.
    line="$(grep -E 'highest occupied' "$out" | tail -1 || true)"
    if [[ -n "$line" ]]; then
        if [[ "$line" == *"lowest unoccupied"* ]]; then
            awk '{print $(NF-1)}' <<<"$line"
        else
            awk '{print $NF}' <<<"$line"
        fi
        return 0
    fi

    return 1
}

# The energy every plot is measured from.
#
# Taken from the NSCF run, NOT the SCF run.
#
# The Fermi level is not read off the charge density; it is found by
# integrating occupations over the k-point mesh, and the SCF mesh is coarser
# than the NSCF one. On a semiconductor an E_F from a coarse SCF mesh can land
# outside the gap entirely, putting the zero line under the valence band.
#
# The NSCF value is also the one dos.x writes into the DOS header, so both
# panels end up on the same zero as the DOS data itself.
plot_fermi_energy() {
    local ef line

    PLOT_EF=""
    PLOT_EF_SOURCE=""

    if ef="$(plot_fermi_from_out "$NSCF_OUT")"; then
        PLOT_EF="$ef"
        PLOT_EF_SOURCE="nscf output - the densest mesh, and what dos.x used"
        return 0
    fi

    # dos.x copies the NSCF Fermi level into its header, so this is the same
    # number by another route - useful when only the data files were kept.
    if [[ -f "$PLOT_DOS_FILE" ]]; then
        line="$(head -1 "$PLOT_DOS_FILE")"
        if [[ "$line" == *EFermi* ]]; then
            PLOT_EF="$(awk '{for(i=1;i<=NF;i++) if($i=="EFermi") print $(i+2)}' <<<"$line")"
            PLOT_EF_SOURCE="dos file header (same value the nscf produced)"
            return 0
        fi
    fi

    if ef="$(plot_fermi_from_out "$SCF_OUT")"; then
        PLOT_EF="$ef"
        PLOT_EF_SOURCE="scf output - COARSE MESH FALLBACK, see the warning below"
        return 0
    fi

    PLOT_EF="0.0"
    PLOT_EF_SOURCE="NOT FOUND - plots are against the raw eigenvalue scale"
    return 0
}

# Tick positions and their labels.
#
# The positions come from bands.x rather than from the path file because the
# path file holds fractional coordinates, while the plot's x axis is distance
# travelled through reciprocal space - bands.x is the only thing that has
# already done that conversion.
#
# The labels come from <case>_band.in, not <case>_band.path, so that the labels
# describe the run that actually produced this data. Editing the path file
# after a run leaves the two disagreeing, and the .in is the one bands.x saw.
plot_collect_ticks() {
    local bandsx_out="$INPUT_DIR/${CASE_NAME}_bandsx.out"
    local labels_from="$BAND_IN"

    PLOT_TICKS=()
    PLOT_LABELS=()

    # An nspin=2 case ran bands.x once per channel, into _bandsx_up.out and
    # _bandsx_dn.out. Both walk the same path, so either gives the same tick
    # positions; the up one is taken. Without this the magnetic cases lost
    # their k-point labels and fell back to numbering them.
    [[ -f "$bandsx_out" ]] || bandsx_out="$INPUT_DIR/${CASE_NAME}_bandsx_up.out"

    [[ -f "$bandsx_out" ]] || return 0

    mapfile -t PLOT_TICKS < <(
        grep 'high-symmetry point' "$bandsx_out" | awk '{print $NF}' || true
    )
    (( ${#PLOT_TICKS[@]} > 0 )) || return 0

    [[ -f "$labels_from" ]] || labels_from="$BAND_PATH_FILE"
    if [[ -f "$labels_from" ]]; then
        mapfile -t PLOT_LABELS < <(
            awk '
                /K_POINTS/  { inkp = 1; next }
                inkp && /!/ {
                    sub(/.*![ \t]*/, "")
                    sub(/[ \t]+$/, "")
                    if (length($0)) print
                }
            ' "$labels_from" || true
        )
    fi

    # A label list that does not line up with the tick list is worse than no
    # labels at all - it puts a name on the wrong point, which is exactly the
    # class of error `init` exists to prevent. Fall back to numbers instead.
    if (( ${#PLOT_LABELS[@]} != ${#PLOT_TICKS[@]} )); then
        if (( ${#PLOT_LABELS[@]} > 0 )); then
            echo "  warning: found ${#PLOT_LABELS[@]} label(s) in $(basename "$labels_from")"
            echo "           but ${#PLOT_TICKS[@]} high-symmetry point(s) in bands.x output."
            echo "           Numbering the ticks instead of guessing which is which."
        fi
        PLOT_LABELS=()
        local i
        for (( i = 1; i <= ${#PLOT_TICKS[@]}; i++ )); do
            PLOT_LABELS+=( "$i" )
        done
    fi
}

# 3 columns = unpolarised, 4 = nspin 2 (E, up, down, integrated).
plot_dos_is_spin() {
    local ncol
    [[ -f "$PLOT_DOS_FILE" ]] || return 1
    ncol="$(awk '!/^[[:space:]]*#/ && NF > 0 { print NF; exit }' "$PLOT_DOS_FILE")"
    [[ -n "$ncol" ]] && (( ncol >= 4 ))
}

#############################
# Python / matplotlib
#############################

plot_write_python() {
    local script="$1"
    local ticks_csv labels_csv

    ticks_csv="$(printf '%s, ' "${PLOT_TICKS[@]}")"
    labels_csv="$(printf '"%s", ' "${PLOT_LABELS[@]}")"

    # Settings block: written unquoted so the values are substituted in.
    cat > "$script" <<EOF
#!/usr/bin/env python3
"""Band structure and DOS for '${CASE_NAME}'.

Written by 'qe.sh plot'. Edit freely and re-run on its own:

    cd $(basename "$INPUT_DIR") && python3 $(basename "$script")

Running 'bash qe.sh plot' again overwrites this file, so keep a copy under a
different name if you have tuned it.
"""

import matplotlib
matplotlib.use("Agg")          # write files; no display needed, works over ssh
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator
import numpy as np

# ------------------------------- settings --------------------------------
CASE       = "${CASE_NAME}"
BANDS_FILE = "${PLOT_BANDS_REL}"        # "" when bands.x has not run
BANDS_DN   = "${PLOT_BANDS_DN_REL}"     # spin-down channel; "" unless nspin=2
DOS_FILE   = "${PLOT_DOS_REL}"          # "" when dos.x has not run

E_FERMI    = ${PLOT_EF}                 # ${PLOT_EF_SOURCE}
EMIN, EMAX = ${PLOT_EMIN}, ${PLOT_EMAX} # eV, relative to E_FERMI

TICKS      = [${ticks_csv%, }]
LABELS     = [${labels_csv%, }]

BAND_COLOR = "#1f4e79"
DOWN_COLOR = "#c00000"
FERMI_COLOR= "#d62728"
DPI        = ${PLOT_DPI}
FMT        = "${PLOT_FORMAT}"
# -------------------------------------------------------------------------
EOF

    # Body: quoted heredoc, so $2 / \Gamma / backticks reach the file intact.
    cat >> "$script" <<'PYEOF'


def pretty(label):
    """Only Gamma gets rewritten. Every other high-symmetry label in the
    lattices this workflow knows is a plain Latin letter already."""
    return r"$\Gamma$" if label.upper() in ("G", "GAMMA") else label


def read_bands(path):
    """bands.dat.gnu is blank-line separated blocks, one block per band."""
    segments, x, y = [], [], []
    with open(path) as fh:
        for line in fh:
            if not line.strip():
                if x:
                    segments.append((np.array(x), np.array(y)))
                    x, y = [], []
                continue
            cols = line.split()
            x.append(float(cols[0]))
            y.append(float(cols[1]))
    if x:
        segments.append((np.array(x), np.array(y)))
    return segments


def read_dos(path):
    """Returns (E, dos_up, dos_down). dos_down is None unless nspin=2."""
    data = np.loadtxt(path)
    if data.shape[1] >= 4:            # E, up, down, integrated
        return data[:, 0], data[:, 1], data[:, 2]
    return data[:, 0], data[:, 1], None


def draw_bands(ax):
    # Only the first curve of each channel carries a label, or the legend would
    # hold one entry per band.
    for i, (x, y) in enumerate(read_bands(BANDS_FILE)):
        ax.plot(x, y - E_FERMI, color=BAND_COLOR, lw=1.1,
                label="spin up" if (i == 0 and BANDS_DN) else None)

    if BANDS_DN:
        for i, (x, y) in enumerate(read_bands(BANDS_DN)):
            ax.plot(x, y - E_FERMI, color=DOWN_COLOR, lw=1.1, ls="--",
                    label="spin down" if i == 0 else None)

    ax.axhline(0.0, color=FERMI_COLOR, ls="--", lw=0.9)

    if BANDS_DN:
        ax.legend(frameon=False, fontsize=8, loc="upper right")

    if TICKS:
        for t in TICKS[1:-1]:
            ax.axvline(t, color="0.65", lw=0.7)
        ax.set_xticks(TICKS)
        ax.set_xticklabels([pretty(l) for l in LABELS])
        ax.set_xlim(TICKS[0], TICKS[-1])
    else:
        ax.set_xlabel("k path")

    ax.set_ylim(EMIN, EMAX)
    ax.set_ylabel(r"E - E$_F$  (eV)")


def draw_dos(ax, energy_on_y=False):
    """energy_on_y puts DOS on the horizontal axis, so the panel can sit
    beside the band panel and share its energy scale."""
    e, up, down = read_dos(DOS_FILE)
    e = e - E_FERMI
    # Scaled to the tallest peak inside the energy window, not the tallest in
    # the file - the deep semi-core states tens of eV below E_F are many times
    # taller than anything near the gap and would flatten the interesting part.
    window = (e >= EMIN) & (e <= EMAX)
    peak = max(up[window].max(), 0.0 if down is None else down[window].max())
    if not peak > 0:
        peak = 1.0             # a window with no states at all; keep an axis

    if energy_on_y:
        ax.plot(up, e, color=BAND_COLOR, lw=1.1,
                label="spin up" if down is not None else None)
        if down is not None:
            ax.plot(-down, e, color=DOWN_COLOR, lw=1.1, label="spin down")
            ax.set_xlim(-peak * 1.05, peak * 1.05)
        else:
            ax.set_xlim(0, peak * 1.05)
        ax.axhline(0.0, color=FERMI_COLOR, ls="--", lw=0.9)
        ax.set_ylim(EMIN, EMAX)
        ax.set_xlabel("DOS\n(states/eV)")
        # prune="lower" drops the leftmost tick label, which otherwise sits
        # right on top of the band panel's last k-point label.
        ax.xaxis.set_major_locator(MaxNLocator(3, prune="lower"))
    else:
        ax.plot(e, up, color=BAND_COLOR, lw=1.1,
                label="spin up" if down is not None else None)
        if down is not None:
            ax.plot(e, -down, color=DOWN_COLOR, lw=1.1, label="spin down")
            ax.set_ylim(-peak * 1.05, peak * 1.05)
        else:
            ax.set_ylim(0, peak * 1.05)
        ax.axvline(0.0, color=FERMI_COLOR, ls="--", lw=0.9)
        ax.set_xlim(EMIN, EMAX)
        ax.set_xlabel(r"E - E$_F$  (eV)")
        ax.set_ylabel("DOS (states/eV)")

    if down is not None:
        ax.legend(frameon=False, fontsize=8)


def save(fig, name):
    out = "%s_%s.%s" % (CASE, name, FMT)
    fig.savefig(out, dpi=DPI, bbox_inches="tight")
    plt.close(fig)
    print("wrote %s" % out)


def main():
    have_bands = bool(BANDS_FILE)
    have_dos = bool(DOS_FILE)

    if have_bands:
        fig, ax = plt.subplots(figsize=(5.5, 4.5))
        draw_bands(ax)
        ax.set_title("%s  band structure" % CASE)
        save(fig, "band")

    if have_dos:
        fig, ax = plt.subplots(figsize=(6.0, 4.0))
        draw_dos(ax)
        ax.set_title("%s  density of states" % CASE)
        save(fig, "dos")

    if have_bands and have_dos:
        fig, (axb, axd) = plt.subplots(
            1, 2, figsize=(7.5, 4.5), sharey=True,
            gridspec_kw={"width_ratios": [3, 1], "wspace": 0.05})
        draw_bands(axb)
        draw_dos(axd, energy_on_y=True)
        axd.set_ylabel("")
        axd.tick_params(labelleft=False)
        fig.suptitle(CASE)
        save(fig, "band_dos")

    if not (have_bands or have_dos):
        print("nothing to plot: neither a bands file nor a dos file was given")


if __name__ == "__main__":
    main()
PYEOF
}

#############################
# gnuplot
#############################

plot_write_gnuplot() {
    local script="$1"
    local xtics="" arrows="" i label sep=""

    for (( i = 0; i < ${#PLOT_TICKS[@]}; i++ )); do
        label="${PLOT_LABELS[$i]}"
        # gnuplot has no lookup table, so Gamma is substituted here instead of
        # in the script the way the Python version does it.
        case "${label^^}" in
            G|GAMMA) label='{/Symbol G}' ;;
        esac
        xtics+="${sep}\"${label}\" ${PLOT_TICKS[$i]}"
        sep=", "

        if (( i > 0 && i < ${#PLOT_TICKS[@]} - 1 )); then
            arrows+="set arrow from ${PLOT_TICKS[$i]},emin to ${PLOT_TICKS[$i]},emax nohead lc rgb \"#a6a6a6\" lw 1 front"$'\n'
        fi
    done

    local xmin="0" xmax=""
    if (( ${#PLOT_TICKS[@]} > 0 )); then
        xmin="${PLOT_TICKS[0]}"
        xmax="${PLOT_TICKS[-1]}"
    fi

    local dos_dw=''
    plot_dos_is_spin && dos_dw='yes'

    # Spin-resolved bands: a second plot line, the same two colours the DOS
    # panel uses, and a key - without one the reader cannot tell which channel
    # is which.
    local band_key="" band_up_title="" band_dn_plot=""
    if [[ -n "$PLOT_BANDS_DN_REL" ]]; then
        band_key="set key on top right"$'\n'
        band_up_title=' t "spin up"'
        # A real newline after the continuation backslash, not the two
        # characters \n - gnuplot needs the plot to actually continue on the
        # next line.
        band_dn_plot=", \\"$'\n'"     \"${PLOT_BANDS_DN_REL}\" u 1:(\$2-EF) w l lw 2 dt 2 lc rgb down_color t \"spin down\""
    fi

    # Height of the tallest DOS peak *inside the energy window*.
    #
    # Needed because gnuplot autoscales the DOS axis over every row in the
    # file, including the deep semi-core states tens of eV below E_F. Those
    # peaks are many times taller than anything near the gap, so without this
    # the side panel of the combined figure is squashed into the left edge.
    local dos_stats=""
    if [[ -n "$PLOT_DOS_REL" ]]; then
        dos_stats="stats \"${PLOT_DOS_REL}\" u ((\$1-EF) >= emin && (\$1-EF) <= emax ? \$2 : 1/0) nooutput
dosmax = STATS_max"
        if [[ -n "$dos_dw" ]]; then
            dos_stats+="
stats \"${PLOT_DOS_REL}\" u ((\$1-EF) >= emin && (\$1-EF) <= emax ? \$3 : 1/0) nooutput
dosmax = (STATS_max > dosmax) ? STATS_max : dosmax"
        fi
        # A window with no states at all would leave an empty range.
        dos_stats+="
if (dosmax <= 0) { dosmax = 1 }"
    fi

    cat > "$script" <<EOF
# Band structure and DOS for '${CASE_NAME}'.
#
# Written by 'qe.sh plot'. Edit freely and re-run on its own:
#
#     cd $(basename "$INPUT_DIR") && gnuplot $(basename "$script")
#
# Running 'bash qe.sh plot' again overwrites this file.

# ------------------------------- settings --------------------------------
CASE       = "${CASE_NAME}"
EF         = ${PLOT_EF}                 # ${PLOT_EF_SOURCE}
emin       = ${PLOT_EMIN}
emax       = ${PLOT_EMAX}
band_color = "#1f4e79"
down_color = "#c00000"
fermi_color= "#d62728"
# -------------------------------------------------------------------------

set terminal pngcairo enhanced size 1400,1150 font "Helvetica,26"
set samples 1000
set border lw 2
set tics nomirror out
set key off
EOF

    if [[ -n "$PLOT_BANDS_REL" ]]; then
        cat >> "$script" <<EOF

##### band structure #####
set output CASE."_band.${PLOT_FORMAT}"
set title CASE." band structure"
set ylabel "E - E_F  (eV)"
set yrange [emin:emax]
set xrange [${xmin}:${xmax}]
set xtics (${xtics})
${arrows}set arrow from ${xmin},0 to ${xmax},0 nohead lc rgb fermi_color lw 2 dt 2 front
${band_key}plot "${PLOT_BANDS_REL}" u 1:(\$2-EF) w l lw 2 lc rgb band_color${band_up_title}${band_dn_plot}
unset arrow
unset key
unset xtics
set xtics
EOF
    fi

    if [[ -n "$PLOT_DOS_REL" ]]; then
        cat >> "$script" <<EOF

##### density of states #####
${dos_stats}

set output CASE."_dos.${PLOT_FORMAT}"
set title CASE." density of states"
set xlabel "E - E_F  (eV)"
set ylabel "DOS (states/eV)"
set xrange [emin:emax]
set yrange [$( [[ -n "$dos_dw" ]] && echo '-dosmax*1.05' || echo '0' ):dosmax*1.05]
set arrow from 0,graph 0 to 0,graph 1 nohead lc rgb fermi_color lw 2 dt 2 front
EOF
        if [[ -n "$dos_dw" ]]; then
            cat >> "$script" <<EOF
set key on top right
plot "${PLOT_DOS_REL}" u (\$1-EF):2      w l lw 2 lc rgb band_color t "spin up", \\
     "${PLOT_DOS_REL}" u (\$1-EF):(-\$3) w l lw 2 lc rgb down_color t "spin down"
unset key
EOF
        else
            cat >> "$script" <<EOF
plot "${PLOT_DOS_REL}" u (\$1-EF):2 w l lw 2 lc rgb band_color
EOF
        fi
        printf 'unset arrow\nset autoscale y\n' >> "$script"
    fi

    if [[ -n "$PLOT_BANDS_REL" && -n "$PLOT_DOS_REL" ]]; then
        cat >> "$script" <<EOF

##### the two side by side, sharing the energy axis #####
set output CASE."_band_dos.${PLOT_FORMAT}"
unset title
set multiplot layout 1,2

# left: bands, 72% of the width
set lmargin at screen 0.12
set rmargin at screen 0.72
set ylabel "E - E_F  (eV)"
set yrange [emin:emax]
set xlabel ""
set xrange [${xmin}:${xmax}]
set xtics (${xtics})
${arrows}set arrow from ${xmin},0 to ${xmax},0 nohead lc rgb fermi_color lw 2 dt 2 front
${band_key}plot "${PLOT_BANDS_REL}" u 1:(\$2-EF) w l lw 2 lc rgb band_color${band_up_title}${band_dn_plot}
unset arrow
unset key

# right: DOS turned on its side, same energy range, no repeated axis label.
# It starts at 0.75 rather than at the band panel's 0.72 so the two sets of
# tick labels do not collide at the seam.
set lmargin at screen 0.75
set rmargin at screen 0.96
set ylabel ""
set format y ""
set xlabel "DOS"
unset xtics
set xrange [$( [[ -n "$dos_dw" ]] && echo '-dosmax*1.05' || echo '0' ):dosmax*1.05]
set xtics dosmax
set format x "%.0f"
plot "${PLOT_DOS_REL}" u 2:(\$1-EF) w l lw 2 lc rgb band_color \\
EOF
        if [[ -n "$dos_dw" ]]; then
            printf '     , "%s" u (-$3):($1-EF) w l lw 2 lc rgb down_color\n' \
                "$PLOT_DOS_REL" >> "$script"
        else
            printf '\n' >> "$script"
        fi
        printf 'unset multiplot\nset format x\nset format y\n' >> "$script"
    fi

    printf '\nset output\n' >> "$script"
}

#############################
# The step
#############################

step_plot() {
    require_cache

    local data_prefix="$PREFIX"

    PLOT_DOS_FILE="$INPUT_DIR/${data_prefix}.dos"
    PLOT_BANDS_REL=""
    PLOT_BANDS_DN_REL=""
    PLOT_DOS_REL=""

    # An nspin=2 case has one file per channel. Both are drawn, in the same two
    # colours the DOS panel uses, so both halves of the combined figure
    # describe the same calculation.
    if [[ -s "$INPUT_DIR/${data_prefix}.bands.up.dat.gnu" ]]; then
        PLOT_BANDS_REL="${data_prefix}.bands.up.dat.gnu"
        [[ -s "$INPUT_DIR/${data_prefix}.bands.dn.dat.gnu" ]] && \
            PLOT_BANDS_DN_REL="${data_prefix}.bands.dn.dat.gnu"

        if [[ -z "$PLOT_BANDS_DN_REL" ]]; then
            echo "  warning: ${data_prefix}.bands.up.dat.gnu is here but the spin-down"
            echo "           file is not. The band panel will show spin up only."
            echo "           Re-run the bandsx step to produce both."
        fi
    elif [[ -s "$INPUT_DIR/${data_prefix}.bands.dat.gnu" ]]; then
        PLOT_BANDS_REL="${data_prefix}.bands.dat.gnu"
    fi

    PLOT_BANDS_FILE="${PLOT_BANDS_REL:+$INPUT_DIR/$PLOT_BANDS_REL}"

    [[ -s "$PLOT_DOS_FILE"   ]] && PLOT_DOS_REL="${data_prefix}.dos"

    if [[ -z "$PLOT_BANDS_REL" && -z "$PLOT_DOS_REL" ]]; then
        echo "  nothing to plot: neither ${PREFIX}.bands.dat.gnu nor ${PREFIX}.dos"
        echo "  is in $INPUT_DIR. Run the bandsx and dos steps first."
        return 0
    fi

    local engine
    engine="$(plot_pick_engine)"

    if [[ "$engine" == "off" ]]; then
        echo "  skipped: PLOT_ENGINE='none' in config.sh"
        return 0
    fi

    if [[ "$engine" == "none" ]]; then
        echo "  no plotting engine available, so only the data files were produced."
        echo "  Install one of:"
        echo "    python3 with matplotlib   (pip install matplotlib)"
        echo "    gnuplot"
        echo "  or copy the case folder to a machine that has one and run:"
        echo "    bash qe.sh plot $INPUT_NAME"
        echo "  Set PLOT_ENGINE in config.sh to silence this ('none') or to force"
        echo "  one engine over the other."
        return 0
    fi

    plot_fermi_energy
    plot_collect_ticks

    echo "  engine    : $engine"
    echo "  E_Fermi   : $PLOT_EF eV  ($PLOT_EF_SOURCE)"
    echo "  window    : ${PLOT_EMIN} .. ${PLOT_EMAX} eV around E_Fermi"
    if (( ${#PLOT_TICKS[@]} > 0 )); then
        echo "  path      : ${PLOT_LABELS[*]}"
    elif [[ -n "$PLOT_BANDS_REL" ]]; then
        echo "  path      : no ${CASE_NAME}_bandsx.out to read tick positions from,"
        echo "              the band x axis will be unlabelled"
    fi
    if [[ "$PLOT_EF_SOURCE" == NOT* ]]; then
        echo "  warning: no Fermi energy found in $(basename "$NSCF_OUT") or"
        echo "           $(basename "$SCF_OUT") - the plots are drawn against the raw"
        echo "           eigenvalue scale, so the dashed line at 0 is meaningless."
        echo "           Edit E_FERMI in the generated script and re-run it."
    elif [[ "$PLOT_EF_SOURCE" == scf* ]]; then
        echo "  warning: falling back to the SCF Fermi energy because"
        echo "           $(basename "$NSCF_OUT") is missing. The SCF mesh is coarser than"
        echo "           the NSCF one, and on a semiconductor its E_F can land outside"
        echo "           the gap - which draws the zero line through a band instead of"
        echo "           between them. Run the nscf step, then 'qe.sh plot' again."
    fi

    local script status=0
    if [[ "$engine" == "python" ]]; then
        script="$INPUT_DIR/${CASE_NAME}_plot.py"
        plot_write_python "$script"
        ( cd "$INPUT_DIR" && python3 "$(basename "$script")" ) || status=$?
    else
        script="$INPUT_DIR/${CASE_NAME}_plot.gnu"
        plot_write_gnuplot "$script"
        ( cd "$INPUT_DIR" && gnuplot "$(basename "$script")" ) || status=$?
    fi

    if (( status != 0 )); then
        echo ""
        echo "  PLOT FAILED (exit $status), but every data file above is intact."
        echo "  The script it tried to run is kept at:"
        echo "    $script"
        echo "  Run it by hand to see the error in full, or set PLOT_ENGINE in"
        echo "  config.sh to the other engine."
        return 0
    fi

    echo "  script    : $(basename "$script")  (editable, re-runnable on its own)"
    return 0
}
