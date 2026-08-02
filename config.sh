#!/bin/bash

#############################
# Quantum ESPRESSO Workflow #
#############################
#
# Settings only. Nothing here may reuse a variable name that parser.cache
# writes (PREFIX, OUTDIR, PSEUDO_DIR, CALCULATION, IBRAV, NAT, NTYP, ECUTWFC,
# ECUTRHO, OCCUPATIONS, SMEARING, DEGAUSS, CONV_THR, MIXING_BETA, CELL_DOFREE,
# ATOMIC_SPECIES, K_POINTS).
#
# This used to be violated: config.sh defined bare SMEARING/DEGAUSS/
# MIXING_BETA, and generate_band.sh / generate_nscf.sh source config.sh AFTER
# parser.cache, so those three silently replaced whatever the input file said.
# Fallbacks are prefixed DEFAULT_ for exactly that reason.

##########
# MPI
##########

# Number of MPI processes.
#
# Written so that the same config.sh is correct on the cluster and on a
# laptop, rather than keeping two copies that drift apart. Under Slurm the
# allocation decides (and #SBATCH --ntasks in qe.sh sets it); anywhere else,
# the machine's core count.
#
# Off the cluster this counts *physical cores*, not threads. `nproc` reports
# hyperthreads (12 on a 6-core laptop), but Open MPI counts a slot per core
# and refuses to start with "not enough slots available in the system" - and
# an SMT sibling is not a second FPU anyway, so oversubscribing would only
# make pw.x slower.
if [[ -n "${SLURM_NTASKS:-}" ]]; then
    NPROC="$SLURM_NTASKS"
else
    NPROC="$(lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
    if [[ -z "$NPROC" ]] || (( NPROC < 1 )); then
        NPROC="$(nproc 2>/dev/null || echo 4)"
    fi
fi

##########
# Environment for the MPI steps
##########
#
# Modules to load before pw.x runs. Empty, or a machine with no `module`
# command at all, means pw.x is taken from PATH - which is what a laptop
# install wants. qe.sh checks pw.x is actually resolvable either way.
if command -v module >/dev/null 2>&1 || [[ "$(type -t module 2>/dev/null)" == "function" ]]; then
    QE_MODULES="intel/2024.0 impi/2021.11.0 mkl materials/qe/7.2-impi"
else
    QE_MODULES=""
fi

##########
# k-point pools
##########
#
# Without pools all NPROC ranks split the same set of plane waves. On a small
# cell that leaves some ranks holding ZERO plane waves, the wavefunction
# record length nbnd*npwx becomes 0, and QE aborts with
#
#     Error in routine diropn (3): wrong record length
#
# preceded by "some processors have no G-vectors for symmetrization".
# Pools divide the ranks into NPOOL groups that each take a subset of the
# k-points, keeping every group's plane-wave share large. Also faster.
#
# Measured on graphene (2 atoms, PAW, 40 Ry, 64 ranks, 121 k-points):
#     NPOOL=1 -> crash        NPOOL=4 / 8 / 16 -> success
#
# NPROC must divide by NPOOL, and NPOOL must not exceed the number of
# k-points. qe.sh rejects a gamma-only case unless NPOOL is 1.
NPOOL_WANTED=4

# NPROC is no longer a fixed 64, so a hardcoded NPOOL would abort on any core
# count it does not divide (a 6-core laptop against NPOOL=4). Take the largest
# divisor of NPROC that does not exceed what was asked for.
NPOOL=1
for _c in $(seq "$NPOOL_WANTED" -1 1); do
    if (( NPROC % _c == 0 )); then
        NPOOL="$_c"
        break
    fi
done
unset _c

##########
# Several cases in one job
##########
#
# 1 = run the cases one after another, each getting the whole allocation.
# N > 1 = run N cases at the same time, each getting NPROC/N ranks.
#
# Sequential is the default because overlapping cases measured far slower on
# this cluster, not faster. Graphene + MoS2, same inputs, same node:
#
#     sequential (64 ranks each, one at a time)  ~2.5 min total
#     overlapped (32 ranks each, at once)        45-51 min total
#
# The work done is identical - 5 SCF cycles, 5 vc-relax steps either way -
# but CPU time per rank blew up ~215x (3.35s -> 12m23s), which is ranks
# burning cycles spinning rather than computing. Two mpirun launched straight
# from a plain batch script do NOT show this, so it is something about how
# they overlap here rather than overlapping being wrong in principle. The
# cause is not pinned down, so treat CASES_PARALLEL > 1 as experimental and
# time it on your own case before trusting it.
CASES_PARALLEL=1

##########
# Executables
##########

PW="pw.x"
BANDS="bands.x"
DOS="dos.x"

# Declared for the stages in README.md that are not implemented yet.
PROJWFC="projwfc.x"
PP="pp.x"
AVERAGE="average.x"

##########
# Fallbacks for parameters the input file omits
##########
#
# Applied ONLY when the key is absent from the input. A value written in the
# input always wins, and parser.sh prints a note whenever a default is used.

# QE's own behaviour when `occupations` is absent. Only correct for systems
# with a gap - a metal must set occupations='smearing' in its input.
DEFAULT_OCCUPATIONS="fixed"

DEFAULT_CONV_THR="1.0d-8"
DEFAULT_MIXING_BETA="0.7"

# Used only when occupations='smearing' and the input omits them.
DEFAULT_SMEARING="mv"
DEFAULT_DEGAUSS="0.02"

##########
# Relaxation
##########
#
# Refuse to go on when the relax did not converge.
#
# pw.x prints JOB DONE. even when BFGS ran out of ionic steps, and the last
# ATOMIC_POSITIONS block in that output is the last step it took, not a
# minimum. Everything after - scf, bands, DOS, and any adsorption energy or
# bond length read off them - would then describe a structure that is not a
# stationary point, with no error anywhere to say so.
#
# 0 turns the refusal into a warning and continues. Only worth setting when
# you already know why a case does not converge and want the numbers anyway.
REQUIRE_RELAX_CONVERGED=1

##########
# DOS / NSCF
##########

# NSCF mesh = SCF mesh x scale. z is left alone only for cells the input
# declares 2D via cell_dofree; a 3D cell gets all three directions scaled.
NSCF_KPOINT_SCALE=2

# DOS bin width
DOS_DELTAE="0.01"

##########
# Band Structure
##########

# Interpolated k-points per segment. The path itself is per case:
# <case>_band.path next to the input file.
BAND_POINTS=40

##########
# Plots
##########
#
# The plot step reads only the finished data files, so it needs no MPI and can
# be re-run on an old case, or on a laptop against data copied down from the
# cluster:
#
#     bash qe.sh plot cases/mos2/mos2_relax.in
#
# It writes <case>_plot.py (or .gnu) next to the data and then runs it. That
# script is meant to be edited - colours, ranges, figure size - and re-run on
# its own without going through qe.sh.

# auto    = matplotlib if python3 has it, else gnuplot, else skip
# python  = force matplotlib
# gnuplot = force gnuplot
# none    = produce the data only, no figures and no message about it
#
# Compute nodes often have gnuplot but no matplotlib, while the reverse is
# usual on a laptop - which is why the default resolves per machine rather
# than naming one engine here.
PLOT_ENGINE="auto"

# Energy window, in eV, relative to E_Fermi. Wide enough to show the gap and
# the bands either side of it for a typical semiconductor; narrow it to zoom.
PLOT_EMIN=-5.0
PLOT_EMAX=5.0

PLOT_DPI=300
PLOT_FORMAT="png"

#############################
# Derived - not meant to be edited below this line
#############################

# run.sh exports these when several cases share one job, so each case gets its
# own slice of the allocation instead of all of them claiming every rank.
# Unset for a normal single-case run.
if [[ -n "${QE_NPROC_OVERRIDE:-}" ]]; then
    NPROC="$QE_NPROC_OVERRIDE"
fi
if [[ -n "${QE_NPOOL_OVERRIDE:-}" ]]; then
    NPOOL="$QE_NPOOL_OVERRIDE"
fi

# Built here, after the overrides, so a per-case rank count is reflected.
MPI="mpirun -np ${NPROC}"

if ! [[ "${NPOOL}" =~ ^[0-9]+$ ]] || (( NPOOL < 1 )); then
    echo "ERROR: NPOOL in config.sh must be a positive integer (got '${NPOOL}')"
    exit 1
fi

if (( NPROC % NPOOL != 0 )); then
    echo "ERROR: NPROC (${NPROC}) is not divisible by NPOOL (${NPOOL})."
    printf 'Valid NPOOL values for this NPROC:'
    for c in 1 2 4 8 16 32 64; do (( NPROC % c == 0 )) && printf ' %s' "$c"; done
    printf '\n'
    exit 1
fi

# Passed to pw.x and bands.x. bands.x must use the same pool layout as the
# run that produced the wavefunctions, so both get the identical flag.
# Written as an if, not `(( ... )) && POOL_FLAG=...`: this file is sourced,
# so the exit status of its last command becomes the status of `source`, and
# under `set -e` a false && test here would kill the calling script whenever
# NPOOL is 1.
POOL_FLAG=""
if (( NPOOL > 1 )); then
    POOL_FLAG="-nk ${NPOOL}"
fi
