#!/bin/bash

#############################
# Quantum ESPRESSO Workflow #
#############################

##########
# MPI
##########

# Number of MPI processes
NPROC=64

# MPI command
MPI="mpirun -np ${NPROC}"

##########
# Executables
##########

PW="pw.x"
BANDS="bands.x"
DOS="dos.x"
PROJWFC="projwfc.x"
PP="pp.x"
AVERAGE="average.x"

##########
# Directories
##########

WORKDIR="./work"
LOGDIR="./logs"

##########
# Default QE Parameters
##########

SCF_CONV_THR="1.0d-8"
MIXING_BETA="0.7"

SMEARING="mv"
DEGAUSS="0.02"

##########
# DOS / NSCF
##########

# NSCF mesh = SCF mesh × scale (x and y only for 2D systems)
NSCF_KPOINT_SCALE=2

# DOS bin width
DOS_DELTAE="0.01"

##########
# Band Structure
##########

# Number of interpolated k-points between high-symmetry points
BAND_POINTS=40

#############################
