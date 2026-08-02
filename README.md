# QE_automation

Author: Arsy Syamil

Runs the whole Quantum ESPRESSO chain for a material from one relax input:
relax, structure extraction, scf, band structure, DOS, and the figures. The
same command works on a laptop and on a Slurm cluster — it detects the machine
rather than being configured for it.

Rewrite of the older `QE_workflow` (v1). v1 is retired and its directory was
deleted from the cluster on 2026-08-02 — everything it did is here, including
its `script/check_job.sh`, which came back as the `check` step. The v1 tree
itself is in git history at commit `d5129af` if it is ever needed.

Layout: a thin `qe.sh` that resolves paths, loads settings, declares which
steps exist and runs them, plus `lib/` with one file per concern. The files are
*sourced* into one process, so there is one environment and one `config.sh` —
which is what v1 got wrong, not the fact that it had several files.

`SETUP.md` is the place to start if you want to *use* this. This file explains
what it does and why it is built this way. `MAINTENANCE.md` records what state
the code is in and which bugs are already fixed — read it before editing.

## Workflow

    parser -> relax -> extract -> cif -> scf -> bands -> DOS -> plot

Thirteen steps in one list (`PIPELINE_STEPS` in `qe.sh`):

| # | Step | |
|---|---|---|
| 1 | `parser` | read the input into `cache/<case>.parser.cache` |
| 2 | `relax` | pw.x on the relax input |
| 3 | `extract` | relaxed geometry out of the relax output |
| 4 | `cif` | `<case>_initial.cif` and `<case>_relaxed.cif` |
| 5–6 | `gen-scf`, `scf` | charge density |
| 7–9 | `gen-band`, `band`, `bandsx` | eigenvalues along the k-path |
| 10–11 | `gen-nscf`, `nscf` | denser mesh for the DOS |
| 12 | `dos` | dos.x |
| 13 | `plot` | band and DOS figures |

PDOS and work function are not implemented; `projwfc.x` / `pp.x` / `average.x`
are declared in `config.sh` for them.

## Usage

    sbatch qe.sh cases/gra                        # every case in that folder
    sbatch qe.sh case_relax.in                    # one case
    sbatch qe.sh caseA_relax.in caseB_relax.in    # a chosen few of them

    bash qe.sh init  case_relax.in    # measure the lattice, write the k-path
    bash qe.sh dump  case_relax.in    # print everything the parser read
    bash qe.sh check case_relax.in    # where the last run got to, and why
    bash qe.sh scf   case_relax.in    # one step on its own, for debugging

    bash qe.sh                        # the full step list

**Naming a folder is the normal way.** It stands for every `*_relax.in` inside
it, in name order: one folder, one job, its cases one after another — the
`run.sh` convention from the cluster, without the hand-written file list that
goes stale. Adding a case to the folder adds it to the run, and nothing else has
to be edited. Not recursive: the folder you name is the folder that runs, so
`qe.sh cases` cannot become a week-long accident.

Naming files instead is for picking a few out of a folder that holds more. A
step name never ends in `_relax.in` and is never a directory, so all three forms
are unambiguous, and any step accepts any of them.

Cases run one after another, each getting the whole allocation. Every input is
validated before anything starts, a failing case does not stop the others, and
the summary names the step each failure stopped at. Exit code 1 if any failed.

Sizing is done per submission rather than by editing `qe.sh`, since flags beat
`#SBATCH` and this file has to stay byte-identical across copies:

    sbatch -p medium-small -t 3-00:00:00 qe.sh cases/ws2_TS

MEASURED, graphene + MoS2 in one job:

    sequential (CASES_PARALLEL=1, default)   3m07s
    overlapped (CASES_PARALLEL=2)            45-51 min

Overlapping is available via `CASES_PARALLEL` but is not recommended here — see
the note in `config.sh`.

## How state moves between steps

Everything is handed on through files next to the input, so any single step can
be re-run on its own once an earlier run has produced what it reads:

    <case>_relax.in
         |
      [parser] ------------> cache/<case>.parser.cache
         |
      [relax] -------------> <case>_relax.out
         |
      [extract] -----------> cache/<case>.structure.in
         |                            |
         +-------------+--------------+
                       v
        [gen-scf]  [gen-band]  [gen-nscf]     + <case>_band.path
                       v
        <case>_scf.in  <case>_band.in  <case>_nscf.in
                       v
              pw.x / bands.x / dos.x
                       v
        <prefix>.bands.dat.gnu    <prefix>.dos
                       v
                    [plot] ------> <case>_band_dos.png

That middle join is the copy-paste this workflow exists to remove: the relaxed
geometry is read once and reused by all three generated inputs.

## What it refuses, and why

Every one of these is a failure that used to finish with exit 0 and different
physics. Refusing is the point of the tool; automating the typing is a side
effect.

**A relax that did not converge.** pw.x prints `JOB DONE.` whether or not the
ionic minimisation converged — a BFGS run that exhausts `nstep` finishes
cleanly and leaves its last step in the output. `relax` and `extract` require
the `bfgs converged in N scf cycles` line QE prints for both `relax` and
`vc-relax`, and stop with the reason and the usual causes when it is absent.
Checked in `extract` too, so it also covers a relax run outside this workflow
and copied in. `REQUIRE_RELAX_CONVERGED=0` in `config.sh` downgrades it to a
warning.

The largest remaining force component is compared against the run's own
`forc_conv_thr` and reported when over. For a `vc-relax` that number comes from
the final scf QE runs at the relaxed cell with recalculated G-vectors, so
exceeding it there means the structure is converged in the basis it started
from rather than in the correct one — Pulay stress, whose remedy is to re-run
`vc-relax` from the final structure until the cell stops moving.

**A k-path that does not belong to the lattice.** `<case>_band.path` is
required, never defaulted. `qe.sh init` measures the cell, classifies the
lattice, prints the classification, and writes the matching path — and refuses
to guess when the cell does not classify. A hexagonal path on a cubic cell
produces a clean band structure of the wrong thing.

**Parameters silently dropped when generating inputs.** `&CONTROL`, `&SYSTEM`
and `&ELECTRONS` are copied through as raw lines minus the keys the generator
writes itself, so `nbnd`, `nspin`, `starting_magnetization(1)`, `vdw_corr`, a
`HUBBARD` card and anything else survive. The parser prints what it carried
over. All 104 production inputs in this project use `vdw_corr = 'DFT-D3'`.

**One spin channel standing in for two.** bands.x writes one channel per run
and defaults to the first, so an `nspin=2` case used to give a spin-up band
panel beside a two-channel DOS panel. The `bandsx` step now runs once per
channel and both figures draw both, up solid and down dashed. Unpolarised
cases are untouched — one pass, same file names.

**Derived files older than their sources.** The cache, the geometry and the
generated inputs are all snapshots. Edit the input and the cache is re-parsed;
re-run the relax and the geometry is re-extracted; edit `<case>_band.path` and
the `band` step stops rather than walking the old path. What you wrote last
wins — and hand-editing a generated input still works, because your edit is
then the newest thing there.

**Missing pseudopotentials, before the queue rather than after.** `pseudo_dir`
and every `.upf` in `ATOMIC_SPECIES` are verified for all cases before the
first one starts. pw.x would find this seconds into a job that queued for
hours. Fatal only for the steps that launch pw.x — preparing inputs on a laptop
against a cluster `pseudo_dir` prints a note and carries on.

**Two cases in one folder writing the same files.** bands.x and dos.x name
their output after `prefix`, so a shared prefix means one `<prefix>.dos` and
whichever case finished last. An absent prefix defaults to the case name; an
explicitly shared one is refused before anything runs.

## When a run is cut short

Each step is recorded in `logs/<case>.status.tsv` *before* it starts, so a step
with no outcome written after it is a step that was interrupted — true even
under SIGKILL, which walltime and the OOM killer both use and no trap can
catch. `qe.sh check` turns that into a sentence:

    Last run of 'gra3' (job 412899, started 2026-08-02 01:52:03):
       1/13  parser    OK       0h0m3s
       2/13  relax     RUNNING  started 2026-08-02 01:52:06

    INTERRUPTED: step 2/13 (relax) started at 2026-08-02 01:52:06 and never
      finished. The process was killed while it was running - walltime,
      scancel, out of memory, or a node failure - so nothing after it ran.
      What killed it:
        sacct -j 412899 --format=JobID,State,ExitCode,Elapsed,Timelimit,MaxRSS

Without it the only evidence is a Slurm log that stops mid-sentence, possibly
hours of pw.x output away from the step header that would name the stage.

`#SBATCH --time` is set rather than left to the partition default, and the
limit actually in force is printed in the run header.

## The structure as CIF

`cif` writes `<case>_initial.cif` and `<case>_relaxed.cif` from data already on
disk — the input and the extracted geometry — so a relaxation can be looked at
in VESTA rather than trusted. No MPI, milliseconds, runnable on a finished case
at any time:

    bash qe.sh cif cases/mos2/mos2_relax.in

Symmetry is written as `P 1` on purpose. A space group guessed from relaxed
coordinates is a CIF that is wrong without saying so; viewers re-detect
symmetry themselves, with a tolerance you control.

## Plots

`plot` closes the pipeline: `<case>_band.png`, `<case>_dos.png`, and the two
side by side sharing one energy axis. Zero on the energy axis is the Fermi
level of the **nscf** run — the densest mesh, and the one dos.x wrote into the
DOS header, so both panels share the DOS data's own zero.

It reads only finished data files — no wavefunctions, no MPI — so it can be
re-run on an old case at any time, including on a laptop against data copied
down from the cluster:

    bash qe.sh plot cases/mos2/mos2_relax.in

`PLOT_ENGINE` in `config.sh` selects matplotlib or gnuplot; `auto` takes
whichever the machine has. Both produce the same figures. Rather than drawing
directly, the step writes `<case>_plot.py` (or `.gnu`) next to the data and runs
that — so tuning a figure is editing a normal script with a settings block at
the top and re-running it on its own.

Deliberately **fail-soft**. It is the last step of a pipeline that may have run
for hours, and a compute node without matplotlib is not a reason to mark a
finished calculation as failed. It says what went wrong and returns success;
the data files are the deliverable.

## Off the cluster

The same `qe.sh` and `config.sh` run on a laptop with no Slurm and no modules,
so the copies stay byte-identical (check with `md5sum`). Drop `sbatch`:

    bash qe.sh case_relax.in

`NPROC` becomes the physical core count instead of the Slurm allocation,
`NPOOL` is clamped to a divisor of it, and pw.x is taken from PATH. If pw.x is
not there, the run says so before starting rather than failing inside MPI.

When `short` is full on the cluster — which it often is — the same job starts
immediately on `sbatch -p interactive qe.sh ...`. Those nodes are shared, so
size any `-t` for a contended run, not an idle one.

## What it takes to add a new material

    <case>_relax.in     ibrav = 0 with an explicit CELL_PARAMETERS card,
                        and K_POINTS automatic (or gamma for a molecule)
    <case>_band.path    written for you by `qe.sh init <case>_relax.in`

`SETUP.md` is the full checklist, including the material types this has been
checked against and the two that are rejected on purpose.

## Files

    qe.sh                              orchestrator + the step registry
    config.sh                          settings you edit
    lib/common.sh                      environment, per-case paths, freshness,
                                       run status, diagnostics
    lib/parser.sh                      reading the relax input, pseudo preflight
    lib/structure.sh                   relaxed geometry + convergence check
    lib/cif.sh                         the structure as CIF, before and after
    lib/generate.sh                    writing the scf / band / nscf inputs
    lib/run.sh                         steps that launch pw.x / bands.x / dos.x
    lib/init.sh                        lattice detection + band path
    lib/plot.sh                        band / DOS figures from the finished data
    SETUP.md                           how to use it
    MAINTENANCE.md                     what is fixed, deliberate, and still open
    template/
      band.path.hex_gamma60_example      reference k-path, NOT applied automatically

Adding a stage is two edits: write `step_<name>()` in the `lib/` file it belongs
to, then add `<name>` to `PIPELINE_STEPS` in `qe.sh` where it runs. The step
counters (`4/13`) come from that list, so nothing needs renumbering.

Per case, next to the input file:

    <case>_relax.in                    your input
    <case>_band.path                   REQUIRED for the band step
    <case>_initial.cif                 structure before the relax
    <case>_relaxed.cif                 structure after it
    cache/<case>.parser.cache          parsed input values
    cache/<case>.structure.in          relaxed geometry
    logs/<case>.status.tsv             which step ran, and how it ended
    <prefix>.bands.dat.gnu             band data      (bands.x)
    <prefix>.bands.{up,dn}.dat.gnu     band data per spin channel, nspin=2
    <prefix>.dos                       DOS data       (dos.x)
    <case>_band.png                    figures        (plot)
    <case>_dos.png
    <case>_band_dos.png
    <case>_plot.py  or  _plot.gnu      the script that drew them - yours to edit

## Verified

Graphene, 2 atoms, full pipeline, both pseudopotential families:

    PAW   C.pbe-n-kjpaw_psl.1.0.0.UPF   40 Ry   COMPLETED 0:0   1m14s
    ONCV  C_ONCV_PBE-1.0.upf            60 Ry   COMPLETED 0:0   1m32s

Cross-check on the result, not just the exit code: the two families put the
Fermi level at -2.322 eV and -2.333 eV, and the DOS goes to ~0 there, which is
the Dirac point of a semimetal.

That run also reported a "relaxed lattice constant" of 2.460 A, exactly its own
input. Read as evidence of a converged cell it was worthless — the cell was
being copied from the input rather than from the relax, the bug fixed in §7
below. The Fermi level and DOS cross-check stand; the lattice constant claim
did not, and has been dropped.

Those directories are workflow tests, not publishable physics — the cutoffs
were picked to exercise the pipeline, not converged.

### Against an external reference (2026-07-29)

Two materials from the CMPT Tohoku QE tutorial, chosen because neither was
written for this workflow — both use `ibrav != 0` with `celldm`, and both start
from `scf` rather than `relax`, so each had to be converted first. Cutoffs and
meshes were reduced to keep them quick on a laptop, so the numbers are close to
but not exactly the tutorial's.

    silicon        FCC, converted from ibrav=2, spin-orbit dropped
                   indirect gap 0.573 eV, CBM ~0.85 of the way G->X,
                   valence bandwidth 11.97 eV
    phosphorene    orthorhombic slab, converted from ibrav=8
                   direct gap 0.646 eV at G

Both band structures reproduce the shape of the tutorial's published figures
along the same paths. PBE underestimating silicon's gap (0.57 vs 1.17 eV
experimental) is the functional behaving normally, not a workflow error.

Phosphorene is what showed `init` had no 2D variant for orthorhombic: at
c/a = 7 it was handed the 3D path, four of whose nine segments run along the
vacuum direction. `orc_2d` and `tet_2d` were added in response.

### Against this project's own production data (2026-08-02)

The convergence check was run over the 40 finished relaxations on the cluster:
**38 converged, 1 stopped at the BFGS step limit** (`mos2_no2_H3`, largest
remaining force component 0.0042 Ry/au against a 1.0E-03 threshold), **1
interrupted**. The one that ran out of steps had previously passed as a success.

## What changed from v1

### 1. Fewer files, and none of them a separate process

`run.sh` plus ten scripts in `script/` became `qe.sh` plus the `lib/` files.

The count was never the point — v1's problem was that each helper was its own
process with its own `config.sh`. These are **sourced**, so there is one
environment and one settings file, and `emit_pw_input()` exists once instead of
being copied three times.

Deleted along the way:

- The preflight loop checking that all eight helper scripts exist. `qe.sh` still
  verifies its `lib/` files are present, but as one loop with a message naming
  the missing file, not eight scattered checks.
- Most of `get_script_dir()`. Not fully gone: Slurm hands the batch script to
  the compute node as a spooled copy whose directory contains neither
  `config.sh` nor `template/`, so `resolve_root_dir()` still has to fall back to
  `SLURM_SUBMIT_DIR`. What the merge removes is the failure mode where eight
  separate helpers had to be found; what remains is a single lookup that
  verifies `config.sh` is actually present before accepting a candidate
  directory, instead of assuming it.
- The `bash -c` wrapper around every step. That existed to stop a login shell
  re-sourcing `/etc/profile` and swapping `mpirun` for one that cannot launch an
  Intel-MPI-linked `pw.x`. Steps are now shell functions in the same process and
  inherit the module environment directly.
- ~225 lines of duplication across `generate_scf.sh` / `generate_band.sh` /
  `generate_nscf.sh`. Those three were 91/109/115 lines differing by only ~35
  lines each; the shared part is now one `emit_pw_input()` function.

### 2. config.sh no longer overwrites your input file  <-- correctness fix

The old `generate_band.sh` and `generate_nscf.sh` did:

    source cache/parser.cache      # your input's real values
    source config.sh               # then clobbered three of them

`config.sh` defined bare `SMEARING`, `DEGAUSS` and `MIXING_BETA` — the same
names `parser.cache` writes. Sourcing it second silently replaced whatever the
input file said. `generate_scf.sh` did not source `config.sh`, so SCF escaped it
and band/nscf did not.

Real effect, from the graphene run of 2026-07-24:

    gra_relax.in   smearing = 'mp'   degauss = 0.01     <- what was written
    gra_scf.in     smearing = 'mp'   degauss = 0.01     <- correct
    gra_band.in    smearing = 'mv'   degauss = 0.02     <- silently replaced

SCF and the band structure were computed with different smearing. The WS2 runs
were unaffected only by coincidence: their inputs already used `mv`/`0.02`,
identical to the config defaults.

In v2 these are `DEFAULT_SMEARING`, `DEFAULT_DEGAUSS`, `DEFAULT_MIXING_BETA`,
`DEFAULT_CONV_THR`. They apply only when the input omits the key, and print a
note when they do. A value in the input always wins.

### 3. The band k-path is per case, and never guessed

The old `template/band.path` held a Gamma-M-K-Gamma path and was applied to
every material unconditionally. That path is correct only for a hexagonal
Brillouin zone. It worked for MoS2, WS2 and graphene because all three are
hexagonal; any other lattice would have produced a band structure along the
wrong path with no error at all.

v2 requires `<case>_band.path` next to the input and fails loudly if it is
missing. `template/band.path.hex_gamma60_example` is a reference to copy from,
not a default.

### 4. Parameters are required only when they mean something

The old parser rejected any input missing `occupations`, `smearing`, `degauss`,
`conv_thr` or `mixing_beta`, regardless of the material. An insulator using
`occupations='fixed'` has no use for `smearing`/`degauss`, and QE ignores them
there.

v2 requires `smearing`/`degauss` only when `occupations='smearing'`, and when
`occupations` is anything else they are not written into the generated inputs at
all. `conv_thr`/`mixing_beta` fall back to the `DEFAULT_*` values.

### 5. NSCF k-mesh scaling respects the actual cell

The old `generate_nscf.sh` scaled only x and y, assuming every material is a 2D
slab like MoS2/WS2. v2 reads `cell_dofree` from the input: a cell declared 2D
keeps its single k-point along z, anything else gets all three scaled.

    2D  (cell_dofree='2Dxy')   15 15 1  ->  30 30 1
    3D  (no cell_dofree)        8  8 8  ->  16 16 16

### 6. k-point pools, which is what actually fixed "PAW does not work"

The band step used to abort with:

    Error in routine diropn (3): wrong record length

This looked like a PAW problem because the PAW run crashed and the ONCV run did
not. It is not. `diropn` raises that error when the record length it is given is
<= 0. The wavefunction record length is `nbnd * npwx`, and `npwx` is the
plane-wave count *on one MPI rank*. With 64 ranks splitting a two-atom cell,
some ranks receive zero plane waves, so the length is 0. QE says so first, in
the line everyone scrolls past:

    Message from routine sym_rho_init:
    some processors have no G-vectors for symmetrization

PAW only made it more likely, by allowing a lower cutoff: at 40 Ry the PAW run
had 24261 G-vectors, while the ONCV run at 60 Ry had 44515 — enough to go round
64 ranks. The same failure would hit ONCV on a smaller cell or a lower cutoff,
and it explains why MoS2/WS2 never tripped it: more electrons, bigger cell, more
plane waves.

Measured directly, PAW graphene, 64 ranks, everything else identical:

    NPOOL=1    2 no-G-vector warnings    CRASH
    NPOOL=4    0 warnings                SUCCESS
    NPOOL=8    0 warnings                SUCCESS
    NPOOL=16   0 warnings                SUCCESS

`NPOOL` in config.sh (default 4) now passes `-nk` to `pw.x` and `bands.x`. Pools
split the ranks into groups that each take a subset of the k-points, so each
group's share of plane waves stays large. It is also faster: the full PAW
pipeline finishes in 1m14s, against 1m32s for the unpooled ONCV run.

`bands.x` gets the same flag deliberately — post-processing has to use the pool
layout of the run that produced the wavefunctions.

Constraints: `NPROC` must divide by `NPOOL`, and `NPOOL` must not exceed the
number of k-points. Both are checked before anything is launched, and
`diagnose_failure()` explains these two aborts (plus a missing pseudopotential)
if they ever come back.

### 7. A vc-relax now keeps the cell it relaxed to  <-- correctness fix

`step_extract()` took `ATOMIC_POSITIONS` from the relax *output* and
`CELL_PARAMETERS` from the relax *input*. Every step after it therefore ran a
`vc-relax` case on the un-relaxed cell holding the relaxed positions — a
structure that was never optimised, and nothing said so.

The cell now comes from the `Begin final coordinates` block of the output,
falling back to the input only when the output has none — which is the correct
answer for a plain `relax`, where the cell does not move. A `vc-` calculation
missing that block warns instead. `step_extract()` prints which source each half
came from.

Inherited from v1, whose `script/extract_structure.sh` still has the bug — see
`git show d5129af:script/extract_structure.sh`.

### 8. Parameters outside the parser's 16 keys are no longer dropped  <-- correctness fix

The generated scf/band/nscf inputs contained only what `get_param()` knew how to
read. Everything else in the input was silently gone: `nbnd`, `nspin`,
`starting_magnetization`, `vdw_corr`, `tefield`/`dipfield`, `edir`, `tot_charge`,
`input_dft`.

For the MoS2 gas-sensor inputs that meant an SCF without the `DFT-D3` dispersion
correction, and a non-magnetic band structure for the `nspin=2` NO2 case. Same
shape as the `nbnd = 120` bug in `../mos2/README.md`: no error, different
physics.

See `MAINTENANCE.md` §1.2 for what is deliberately dropped and why.

## Not changed

- `pw.x` / `bands.x` / `dos.x` invocation, MPI setup, and module list are the
  same as the old pipeline.
- `slurm-<jobid>.out` still lands in this directory.
