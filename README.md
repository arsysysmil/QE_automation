# QE Workflow v2

Author: Arsy Syamil

Rewrite of `../QE_workflow` (v1). v1 is retired — everything it did is here,
including its `script/check_job.sh`, which came back as the `check` step.

Layout: a thin `qe.sh` that resolves paths, loads settings, declares which
steps exist and runs them, plus `lib/` with one file per concern. The files are
*sourced* into one process, so there is one environment and one `config.sh` —
which is what v1 got wrong, not the fact that it had several files.

## Workflow

    Relax -> SCF -> Bands -> DOS         (implemented)
    PDOS -> Work Function -> Plotting    (planned; projwfc.x / pp.x / average.x
                                          are declared in config.sh for these)

## Usage

    sbatch qe.sh case_relax.in                    # full pipeline
    sbatch qe.sh caseA_relax.in caseB_relax.in    # several cases, one job

    bash qe.sh parser case_relax.in    # run a single step, for debugging
    bash qe.sh dump   case_relax.in    # print everything the parser read
    bash qe.sh gen-scf case_relax.in
    bash qe.sh scf     case_relax.in
    bash qe.sh check   case_relax.in   # which stages finished, and why not

A step name never ends in `_relax.in`, so both forms are unambiguous and any
step accepts several cases (`qe.sh scf a_relax.in b_relax.in`).

Several cases run one after another, each getting the whole allocation. Every
input is validated before anything starts, a failing case does not stop the
others, and a summary is printed at the end (exit code 1 if any failed).

MEASURED, graphene + MoS2 in one job:

    sequential (CASES_PARALLEL=1, default)   3m07s
    overlapped (CASES_PARALLEL=2)            45-51 min

Overlapping is available via CASES_PARALLEL in config.sh but is not
recommended here - see the note in that file.

Steps hand state to each other through `cache/parser.cache` next to the input
file, so any single step can be re-run on its own after an earlier run created
it. `qe.sh` with no arguments prints the full step list.

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
    <case>_band.path    the high-symmetry path for THIS lattice

Anything else the input declares — `nbnd`, `nspin`, `vdw_corr`, a `HUBBARD`
card, ... — is carried into the generated scf/band/nscf inputs automatically.
`SETUP.md` is the full checklist, including the material types this has been
checked against and the two that are rejected on purpose.

## Files

    qe.sh                              orchestrator + the step registry
    config.sh                          settings you edit
    lib/common.sh                      environment, per-case paths, diagnostics
    lib/parser.sh                      reading the relax input
    lib/structure.sh                   relaxed geometry out of the relax output
    lib/generate.sh                    writing the scf / band / nscf inputs
    lib/run.sh                         steps that launch pw.x / bands.x / dos.x
    SETUP.md                           what an input must satisfy to be accepted
    MAINTENANCE.md                     what is fixed, deliberate, and still open
    template/
      band.path.hexagonal_example      reference k-path, NOT applied automatically

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
    cache/parser.cache                 parsed input values
    cache/structure.in                 relaxed geometry

## What changed from QE_workflow

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
missing. `template/band.path.hexagonal_example` is a reference to copy from,
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
