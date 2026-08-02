# QE_automation

Author: Arsy Syamil

Rewrite of the older `QE_workflow` (v1). v1 is retired — everything it did is here,
including its `script/check_job.sh`, which came back as the `check` step.

Layout: a thin `qe.sh` that resolves paths, loads settings, declares which
steps exist and runs them, plus `lib/` with one file per concern. The files are
*sourced* into one process, so there is one environment and one `config.sh` —
which is what v1 got wrong, not the fact that it had several files.

## Workflow

    Relax -> SCF -> Bands -> DOS -> Plot   (implemented)
    PDOS -> Work Function                  (planned; projwfc.x / pp.x /
                                            average.x are declared in
                                            config.sh for these)

## Usage

    sbatch qe.sh case_relax.in                    # full pipeline
    sbatch qe.sh caseA_relax.in caseB_relax.in    # several cases, one job
    sbatch qe.sh cases/gra                        # every case in that folder

    bash qe.sh parser case_relax.in    # run a single step, for debugging
    bash qe.sh dump   case_relax.in    # print everything the parser read
    bash qe.sh gen-scf case_relax.in
    bash qe.sh scf     case_relax.in
    bash qe.sh check   case_relax.in   # where the last run got to, and why

A step name never ends in `_relax.in`, so both forms are unambiguous and any
step accepts several cases (`qe.sh scf a_relax.in b_relax.in`).

A **folder** argument stands for every `*_relax.in` inside it, in name order:
one folder, one job, its cases one after another — the `run.sh` convention
from the cluster, without the hand-written file list that goes stale. Adding a
case to the folder adds it to the run. It is not recursive: the folder you
name is the folder that runs, so `qe.sh cases` cannot become a week-long
accident.

Everything each case produces is named after that case — `gra1_scf.in`,
`gra1.dos`, `gra1.bands.dat.gnu` — so a folder of cases keeps its results
apart. An input that sets `prefix` itself still wins, and two cases in one
folder that would end up sharing one are refused before anything starts.

Several cases run one after another, each getting the whole allocation. Every
input is validated before anything starts, a failing case does not stop the
others, and a summary is printed at the end naming the step each failure
stopped at. Exit code 1 if any failed.

### The structure as CIF, before and after

The `cif` step writes `<case>_initial.cif` and `<case>_relaxed.cif` from data
already on disk - the input and the extracted geometry - so the relaxation can
be looked at in VESTA rather than trusted. No MPI, milliseconds, and runnable
on a finished case at any time:

    bash qe.sh cif cases/mos2/mos2_relax.in

Symmetry is written as `P 1` on purpose. A space group guessed from relaxed
coordinates is a CIF that is wrong without saying so; viewers re-detect
symmetry themselves, with a tolerance you control.

### Nothing derived is older than what it came from

The input is parsed into a cache, the relax output into a geometry, and those
into the generated scf/band/nscf inputs. Each of those is a snapshot, and each
is now checked against what it was taken from. Edit the input and the cache is
re-parsed; re-run the relax and the geometry is re-extracted; edit
`<case>_band.path` and the `band` step stops rather than walking the old
k-path. What you wrote last wins.

Hand-editing a generated input still works - your edit is the newest thing
there, so nothing complains about it.

### Walltime is written down

`#SBATCH --time` is set in `qe.sh` and the limit actually in force is printed
in the run header. Size it per job on the command line rather than editing the
file, since flags beat `#SBATCH`:

    sbatch -p medium-small -t 3-00:00:00 qe.sh cases/ws2_TS

### Spin-polarised cases get both channels

bands.x writes one spin channel per run and defaults to the first, so an
`nspin=2` case used to produce a band figure of spin up only - beside a DOS
panel that showed both, because dos.x writes both without being asked. The
bandsx step now runs once per channel and the figures draw both, up solid and
down dashed, in the same two colours the DOS panel uses.

Unpolarised cases are unchanged: one pass, `<prefix>.bands.dat`, same file
names as before.

### Pseudopotentials are checked before the queue

`pseudo_dir` and every `.upf` file named in `ATOMIC_SPECIES` are verified for
all cases before the first one starts. pw.x would find a missing file a few
seconds into a job that queued for hours; this finds it in the second before
submission, and reports every case at once so a folder of ten is fixed in one
pass.

Fatal only for the steps that launch pw.x. Preparing inputs on a laptop, where
`pseudo_dir` names a path that only exists on the cluster, prints a note and
carries on - `parser`, `dump`, `gen-scf`, `plot` and `check` do not need the
files.

### A relax that did not converge is refused

pw.x prints `JOB DONE.` whether or not the ionic minimisation converged — a
BFGS run that exhausts `nstep` finishes cleanly and leaves its last step in the
output. The `relax` and `extract` steps therefore require the
`bfgs converged in N scf cycles` line that QE prints for both `relax` and
`vc-relax`, and stop with the reason and a list of what usually causes it when
it is absent. Without that, everything downstream — scf, bands, DOS, and any
adsorption energy or bond length read off them — describes a structure that is
not a minimum, with nothing anywhere to say so.

Checked in `extract` as well as in `relax`, so it also covers a relax run
outside this workflow and copied in. `REQUIRE_RELAX_CONVERGED=0` in
`config.sh` downgrades it to a warning.

The largest remaining force component is compared against the run's own
`forc_conv_thr`, and reported when it is over. For a `vc-relax` that is the
final scf QE runs at the relaxed cell with recalculated G-vectors, so exceeding
it there means the structure is converged in the basis it started from rather
than in the correct one — Pulay stress, whose remedy is to re-run `vc-relax`
from the final structure until the cell stops moving.

### When a run is cut short

Each step is recorded in `logs/<case>.status.tsv` *before* it starts, so a
step with no outcome written after it is a step that was interrupted — true
even under SIGKILL, which walltime and the OOM killer both use and no trap can
catch. `qe.sh check` turns that into a sentence:

    Last run of 'gra3' (job 412899, started 2026-08-02 01:52:03):
       1/12  parser    OK       0h0m3s
       2/12  relax     RUNNING  started 2026-08-02 01:52:06

    INTERRUPTED: step 2/12 (relax) started at 2026-08-02 01:52:06 and never
      finished. The process was killed while it was running - walltime,
      scancel, out of memory, or a node failure - so nothing after it ran.
      What killed it:
        sacct -j 412899 --format=JobID,State,ExitCode,Elapsed,Timelimit,MaxRSS

Without it the only evidence is a Slurm log that stops mid-sentence, possibly
hours of pw.x output away from the step header that would name the stage.

MEASURED, graphene + MoS2 in one job:

    sequential (CASES_PARALLEL=1, default)   3m07s
    overlapped (CASES_PARALLEL=2)            45-51 min

Overlapping is available via CASES_PARALLEL in config.sh but is not
recommended here - see the note in that file.

Steps hand state to each other through `cache/<case>.parser.cache` next to the
input file, so any single step can be re-run on its own after an earlier run
created it. `qe.sh` with no arguments prints the full step list.

### Off the cluster

The same `qe.sh` and `config.sh` run on a laptop with no Slurm and no modules
— they detect the machine rather than being configured for it, so the two
copies stay byte-identical (check with `md5sum`). Drop `sbatch`:

    bash qe.sh case_relax.in

`NPROC` becomes the physical core count instead of the Slurm allocation,
`NPOOL` is clamped to a divisor of it, and pw.x is taken from PATH. If pw.x is
not there, the run says so before starting rather than failing inside MPI.

When `short` is full on the cluster — which it often is — the same job starts
immediately on `sbatch -p interactive qe.sh ...`. Those nodes are shared, so
size any `-t` for a contended run, not an idle one.

### What it takes to add a new material

    <case>_relax.in     ibrav = 0 with an explicit CELL_PARAMETERS card,
                        and K_POINTS automatic (or gamma for a molecule)
    <case>_band.path    written for you by `qe.sh init <case>_relax.in`, which
                        measures the lattice and picks the matching path

Anything else the input declares — `nbnd`, `nspin`, `vdw_corr`, a `HUBBARD`
card, ... — is carried into the generated scf/band/nscf inputs automatically.
`SETUP.md` is the full checklist, including the material types this has been
checked against and the two that are rejected on purpose.

### Plots

The `plot` step closes the pipeline: `<case>_band.png`, `<case>_dos.png`, and
the two side by side sharing one energy axis. Everything is measured from the
Fermi energy of the SCF run, so 0 on the y axis is E_F.

It reads only finished data files — no wavefunctions, no MPI — so it can be
re-run on an old case at any time, including on a laptop against data copied
down from the cluster:

    bash qe.sh plot cases/mos2/mos2_relax.in

`PLOT_ENGINE` in `config.sh` selects matplotlib or gnuplot; `auto` takes
whichever the machine has. Both produce the same figures. Rather than drawing
directly, the step writes `<case>_plot.py` (or `.gnu`) next to the data and
runs that — so tuning a figure is editing a normal script with a settings
block at the top and re-running it on its own, without going through `qe.sh`.

This step is deliberately **fail-soft**. It is the last step of a pipeline that
may have run for hours, and a compute node without matplotlib is not a reason
to mark a finished calculation as failed. It says what went wrong and returns
success; the data files are the deliverable.

## Files

    qe.sh                              orchestrator + the step registry
    config.sh                          settings you edit
    lib/common.sh                      environment, per-case paths, diagnostics
    lib/parser.sh                      reading the relax input
    lib/structure.sh                   relaxed geometry out of the relax output
    lib/generate.sh                    writing the scf / band / nscf inputs
    lib/run.sh                         steps that launch pw.x / bands.x / dos.x
    lib/init.sh                        lattice detection + band path
    lib/cif.sh                         the structure as CIF, before and after
    lib/plot.sh                        band / DOS figures from the finished data
    SETUP.md                           what an input must satisfy to be accepted
    MAINTENANCE.md                     what is fixed, deliberate, and still open
    template/
      band.path.hex_gamma60_example      reference k-path, NOT applied automatically

Adding a stage is two edits: write `step_<name>()` in the `lib/` file it
belongs to, then add `<name>` to `PIPELINE_STEPS` in `qe.sh` where it runs. The
step counters (`3/11`) come from that list, so nothing needs renumbering.

Three documents, three audiences. **`SETUP.md` is the one to start with** — a
numbered walkthrough from an empty folder to a finished band structure and
DOS. This file explains what the workflow does and why it is built this way.
`MAINTENANCE.md` records what state the code is in and which bugs are already
fixed — read it before editing `qe.sh`.

Per case, next to the input file:

    <case>_relax.in                    your input
    <case>_band.path                   REQUIRED for the band step (see below)
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

## What changed from v1

### 1. Six files instead of twelve, and none of them a separate process

`run.sh` plus ten scripts in `script/` became `qe.sh` + five `lib/` files.

The count was never the point — v1's problem was that each helper was its own
process with its own `config.sh`. These are **sourced**, so there is one
environment and one settings file, and `emit_pw_input()` exists once instead of
being copied three times.

Deleted along the way:

- The preflight loop checking that all eight helper scripts exist. `qe.sh`
  still verifies its five `lib/` files are present, but as one loop with a
  message naming the missing file, not eight scattered checks.
- Most of `get_script_dir()`. Note it is not fully gone: Slurm hands the batch
  script to the compute node as a spooled copy whose directory contains
  neither `config.sh` nor `template/`, so `resolve_root_dir()` still has to
  fall back to `SLURM_SUBMIT_DIR`. What the merge removes is the failure mode
  where eight separate helpers had to be found; what remains is a single
  lookup that verifies `config.sh` is actually present before accepting a
  candidate directory, instead of assuming it.
- The `bash -c` wrapper around every step. That existed to stop a login shell
  re-sourcing `/etc/profile` and swapping `mpirun` for one that cannot launch
  an Intel-MPI-linked `pw.x`. Steps are now shell functions in the same
  process and inherit the module environment directly.
- ~225 lines of duplication across `generate_scf.sh` / `generate_band.sh` /
  `generate_nscf.sh`. Those three were 91/109/115 lines differing by only
  ~35 lines each; the shared part is now one `emit_pw_input()` function.

### 2. config.sh no longer overwrites your input file  <-- correctness fix

The old `generate_band.sh` and `generate_nscf.sh` did:

    source cache/parser.cache      # your input's real values
    source config.sh               # then clobbered three of them

`config.sh` defined bare `SMEARING`, `DEGAUSS` and `MIXING_BETA` — the same
names `parser.cache` writes. Sourcing it second silently replaced whatever the
input file said. `generate_scf.sh` did not source `config.sh`, so SCF escaped
it and band/nscf did not.

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

The old parser rejected any input missing `occupations`, `smearing`,
`degauss`, `conv_thr` or `mixing_beta`, regardless of the material. An
insulator using `occupations='fixed'` has no use for `smearing`/`degauss`,
and QE ignores them there.

v2 requires `smearing`/`degauss` only when `occupations='smearing'`, and when
`occupations` is anything else they are not written into the generated inputs
at all. `conv_thr`/`mixing_beta` fall back to the `DEFAULT_*` values.

### 5. NSCF k-mesh scaling respects the actual cell

The old `generate_nscf.sh` scaled only x and y, assuming every material is a
2D slab like MoS2/WS2. v2 reads `cell_dofree` from the input: a cell declared
2D keeps its single k-point along z, anything else gets all three scaled.

    2D  (cell_dofree='2Dxy')   15 15 1  ->  30 30 1
    3D  (no cell_dofree)        8  8 8  ->  16 16 16

### 6. k-point pools, which is what actually fixed "PAW does not work"

The band step used to abort with:

    Error in routine diropn (3): wrong record length

This looked like a PAW problem because the PAW run crashed and the ONCV run
did not. It is not. `diropn` raises that error when the record length it is
given is <= 0. The wavefunction record length is `nbnd * npwx`, and `npwx` is
the plane-wave count *on one MPI rank*. With 64 ranks splitting a two-atom
cell, some ranks receive zero plane waves, so the length is 0. QE says so
first, in the line everyone scrolls past:

    Message from routine sym_rho_init:
    some processors have no G-vectors for symmetrization

PAW only made it more likely, by allowing a lower cutoff: at 40 Ry the PAW run
had 24261 G-vectors, while the ONCV run at 60 Ry had 44515 - enough to go
round 64 ranks. Same failure would hit ONCV on a smaller cell or a lower
cutoff, and it explains why MoS2/WS2 never tripped it: more electrons, bigger
cell, more plane waves.

Measured directly, PAW graphene, 64 ranks, everything else identical:

    NPOOL=1    2 no-G-vector warnings    CRASH
    NPOOL=4    0 warnings                SUCCESS
    NPOOL=8    0 warnings                SUCCESS
    NPOOL=16   0 warnings                SUCCESS

`NPOOL` in config.sh (default 4) now passes `-nk` to `pw.x` and `bands.x`.
Pools split the ranks into groups that each take a subset of the k-points, so
each group's share of plane waves stays large. It is also faster: the full
PAW pipeline finishes in 1m14s, against 1m32s for the unpooled ONCV run.

`bands.x` gets the same flag deliberately - post-processing has to use the
same pool layout as the run that produced the wavefunctions.

Constraints: `NPROC` must divide by `NPOOL`, and `NPOOL` must not exceed the
number of k-points. Both are checked before anything is launched, and
`diagnose_failure()` explains these two aborts (plus a missing
pseudopotential) if they ever come back.

### 7. A vc-relax now keeps the cell it relaxed to  <-- correctness fix, 2026-07-27

`step_extract()` took `ATOMIC_POSITIONS` from the relax *output* and
`CELL_PARAMETERS` from the relax *input*. Every step after it therefore ran a
`vc-relax` case on the un-relaxed cell holding the relaxed positions - a
structure that was never optimised, and nothing said so. It also made the
"relaxed lattice constant" this README reported equal to the input value by
construction.

The cell now comes from the `Begin final coordinates` block of the output,
falling back to the input only when the output has none - which is the correct
answer for a plain `relax`, where the cell does not move. A `vc-` calculation
missing that block warns instead. `step_extract()` prints which source each
half came from.

Inherited from v1; `../QE_workflow/script/extract_structure.sh` still has it
and is left alone on purpose.

### 8. Parameters outside the parser's 16 keys are no longer dropped  <-- correctness fix, 2026-07-27

The generated scf/band/nscf inputs contained only what `get_param()` knew how
to read. Everything else in the input was silently gone: `nbnd`, `nspin`,
`starting_magnetization`, `vdw_corr`, `tefield`/`dipfield`, `edir`,
`tot_charge`, `input_dft`.

For the MoS2 gas-sensor inputs that meant an SCF without the `DFT-D3`
dispersion correction, and a non-magnetic band structure for the `nspin=2`
NO2 case. Same shape as the `nbnd = 120` bug in `../mos2/README.md`: no error,
different physics.

`&CONTROL`, `&SYSTEM` and `&ELECTRONS` are now copied through as raw lines
minus the keys the generator writes itself, so indexed forms like
`starting_magnetization(1) = 0.5` survive untouched. The parser prints what it
carried over. See `MAINTENANCE.md` §1.2 for what is dropped and why.

## Not changed

- `pw.x` / `bands.x` / `dos.x` invocation, MPI setup, and module list are the
  same as the old pipeline.
- `slurm-<jobid>.out` still lands in this directory.

## Verified

Graphene, 2 atoms, full 11-step pipeline, both pseudopotential families:

    PAW   C.pbe-n-kjpaw_psl.1.0.0.UPF   40 Ry   COMPLETED 0:0   1m14s
    ONCV  C_ONCV_PBE-1.0.upf            60 Ry   COMPLETED 0:0   1m32s

Cross-check on the result, not just the exit code: the two families put the
Fermi level at -2.322 eV and -2.333 eV, and the DOS goes to ~0 there, which is
the Dirac point of a semimetal.

That run also reported a "relaxed lattice constant" of 2.460 A, exactly its
own input. Read as evidence of a converged cell it was worthless - the cell
was being copied from the input rather than from the relax, which is the bug
fixed in §7. The Fermi level and DOS cross-check above stand; the lattice
constant claim did not, and has been dropped.

Those directories are workflow tests, not publishable physics - the cutoffs
were picked to exercise the pipeline, not converged.

### Against an external reference (2026-07-29)

Two materials from the CMPT Tohoku QE tutorial, chosen because neither was
written for this workflow - both use `ibrav != 0` with `celldm`, and both start
from `scf` rather than `relax`, so each had to be converted first. Cutoffs and
meshes were reduced to keep them quick on a laptop, so the numbers are close
to but not exactly the tutorial's.

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
