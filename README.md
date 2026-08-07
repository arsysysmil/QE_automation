# QE_automation

Author: Arsy Syamil

Runs the whole Quantum ESPRESSO chain for a material from one relax input:
relax, structure extraction, scf, band structure, DOS, and the figures. The
same command works on a laptop and on a Slurm cluster — it detects the machine
rather than being configured for it.

Layout: a thin `qe.sh` that resolves paths, loads settings, declares which
steps exist and runs them, plus `lib/` with one file per concern. The files are
*sourced* into one process, so there is one environment and one `config.sh`.

`SETUP.md` is the usage manual, in Indonesian, and is the place to start if you
want to run this. This file is the reference: the pipeline, the input contract,
the checks, and what is not implemented.

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
it, in name order: one folder, one job, its cases one after another. Adding a
case to the folder adds it to the run, and nothing else has to be edited. Not
recursive: the folder you name is the folder that runs.

Naming files instead is for picking a few out of a folder that holds more. A
step name never ends in `_relax.in` and is never a directory, so all three forms
are unambiguous, and any step accepts any of them.

Cases run one after another, each getting the whole allocation. Every input is
validated before anything starts, a failing case does not stop the others, and
the summary names the step each failure stopped at. Exit code 1 if any failed.

Size the job per submission rather than by editing `qe.sh`, since flags beat
`#SBATCH` and this file is meant to stay identical across machines:

    sbatch -p medium-small -t 3-00:00:00 qe.sh cases/ws2_TS

`-p` and `-t` move together. Where the cluster runs `EnforcePartLimits = NO`, a
job asking for more time than its partition allows is **accepted rather than
rejected**, and then sits `PENDING` with reason `PartitionTimeLimit` forever.
The `#SBATCH --time=24:00:00` in the header matches the cap of the default
`short` partition, so the defaults are consistent on their own.

`CASES_PARALLEL > 1` overlaps cases instead of running them in sequence. It is
available but not recommended — it measured far slower here than sequential.
See the note in `config.sh`.

## Input contract

    <case>_relax.in     ibrav = 0 with an explicit CELL_PARAMETERS card,
                        and K_POINTS automatic (or gamma for a molecule)
    <case>_band.path    written for you by `qe.sh init <case>_relax.in`

The file name must end in `_relax.in`; everything the case produces is named
from the part before it. `calculation` must be `relax` or `vc-relax`.
`&SYSTEM` must carry `ibrav`, `nat`, `ntyp`, `ecutwfc`; `&CONTROL` must carry
`pseudo_dir`, and every `.UPF` named in `ATOMIC_SPECIES` must exist there.

Two forms are refused on purpose:

| Refused | Why |
|---|---|
| `ibrav != 0` (celldm / A,B,C) | no `CELL_PARAMETERS` card to hand between steps; fails at `extract` |
| explicit k-list (`K_POINTS crystal` / `tpiba`) | no mesh for the nscf step to densify; rejected in step 1 |

Both fail with a message naming the cause and the fix. Converting an
`ibrav != 0` input means computing the three lattice vectors from `celldm`,
writing them as a card, and setting `ibrav = 0`.

Everything else has been checked and works: 2D slabs and 3D bulk of any Bravais
lattice, insulators with `occupations='fixed'`, metals with smearing,
spin-polarised (`nspin=2`, `starting_magnetization`), dispersion-corrected
(`vdw_corr`), DFT+U in either the QE 6.x (`lda_plus_u`) or QE 7.x (`HUBBARD`)
form, three or more species, and isolated molecules on `K_POINTS gamma` with
`NPOOL_WANTED=1`.

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

One exception to "any step can be re-run on its own": **`bandsx` must not be
re-run after `nscf`.** All four pw.x stages share one `outdir` and `prefix`, so
once the pipeline has finished, the wavefunctions in `work/<prefix>.save` are
the nscf ones, and a second `bandsx` would produce a "band structure" over the
nscf mesh. Re-run `band` first, or run the whole pipeline.

## What it refuses, and why

Every one of these is a failure that would otherwise finish with exit 0 and
different physics. Refusing is the point of the tool; automating the typing is
a side effect.

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
`vc-relax` from the final structure until the cell stops moving, or to raise
`ecutwfc` until the two agree.

**A k-path that does not belong to the lattice.** `<case>_band.path` is
required, never defaulted. `qe.sh init` measures the cell, classifies the
lattice, prints the classification, and writes the matching path — and refuses
to guess when the cell does not classify. A hexagonal path on a cubic cell
produces a clean band structure of the wrong thing.

The hexagonal case has two settings that are the same lattice but not the same
reciprocal basis: K is at (1/3, 1/3, 0) for γ = 120° and (2/3, 1/3, 0) for
γ = 60°. `template/` holds an example path for each.

**Parameters silently dropped when generating inputs.** `&CONTROL`, `&SYSTEM`
and `&ELECTRONS` are copied through as raw lines minus the keys the generator
writes itself, so `nbnd`, `nspin`, `starting_magnetization(1)`, `vdw_corr`, a
`HUBBARD` card and anything else survive. The parser prints what it carried
over.

**One spin channel standing in for two.** bands.x writes one channel per run
and defaults to the first, so an `nspin=2` case would give a spin-up band panel
beside a two-channel DOS panel. The `bandsx` step runs once per channel and
both figures draw both, up solid and down dashed. Unpolarised cases take the
single-pass path.

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

## What it does not check

These finish with exit 0 and are still your responsibility:

- **Convergence of the parameters themselves** — vacuum thickness, `ecutwfc`,
  the `ecutrho/ecutwfc` ratio (PAW wants 8–10×, not the default 4×), k-mesh
  density. Run those tests separately, before using this.
- **`nbnd`** is passed through but never raised. With `occupations='fixed'` QE
  sets `nbnd = nelec/2` exactly, i.e. no conduction bands at all, and the upper
  half of the band and DOS figures comes out empty. Set `nbnd` in `&SYSTEM`.
- **Whether the k-path suits the lattice** — `init` prints its classification
  for you to check; nothing verifies the path you keep.

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

There is no resume: a killed run leaves a half-written `work/`, so restart it
with `rm -rf <case_dir>/{work,cache,logs}` first.

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
the top and re-running it on its own. `PLOT_EMIN` / `PLOT_EMAX` in `config.sh`
set the energy window for new plots; the same values appear as `EMIN, EMAX` at
the top of the generated script for an existing one.

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

`NPOOL` passes `-nk` to `pw.x` and `bands.x`. Pools split the ranks into groups
that each take a subset of the k-points, which keeps each group's share of
plane waves large — without them, a small cell on many ranks leaves some ranks
with zero G-vectors and `bands.x` aborts with
`Error in routine diropn (3): wrong record length`. Constraints: `NPROC` must
divide by `NPOOL`, and `NPOOL` must not exceed the number of k-points. Both are
checked before anything is launched. `bands.x` gets the same flag deliberately
— post-processing has to use the pool layout of the run that produced the
wavefunctions. `dos.x` gets none.

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
    template/
      band.path.hex_gamma60_example      reference k-path, NOT applied automatically
      band.path.hex_gamma120_example

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

## Working on the code

Adding a stage is two edits: write `step_<name>()` in the `lib/` file it belongs
to, then add `<name>` to `PIPELINE_STEPS` in `qe.sh` where it runs. The step
counters (`4/13`) come from that list, so nothing needs renumbering.

Every step except the four that launch MPI runs on a login node in seconds, so
a change can be checked without submitting anything:

    bash qe.sh parser   <case>_relax.in
    bash qe.sh dump     <case>_relax.in
    bash qe.sh extract  <case>_relax.in     # needs an existing <case>_relax.out
    bash qe.sh gen-scf  <case>_relax.in
    bash qe.sh gen-band <case>_relax.in
    bash qe.sh gen-nscf <case>_relax.in

A hand-written `<case>_relax.out` containing nothing but a
`Begin final coordinates` block is enough to exercise `extract` and all three
generators. Make its final cell differ from the input cell, so the two sources
are distinguishable in the extracted structure.

There are no automated tests. When `short` is full, `sbatch -p interactive`
starts immediately, but those nodes are shared — size any `-t` for a contended
run, not an idle one.

## Not implemented

- `ibrav != 0` is not converted to `CELL_PARAMETERS`; that conversion is manual.
- No automated test suite.
- A job cut short cannot be resumed, only restarted.
- PDOS and the work function.
- The 2D lattice test is `c/a > 2.0`, which is right for monolayers and wrong
  for genuinely layered 3D crystals such as graphite (c/a = 2.7) or bulk
  2H-MoS₂ (c/a = 3.9) — both would lose the Γ–A dispersion.
- `convergence NOT achieved` in an scf is caught but not diagnosed, so it
  prints raw pw.x output rather than a hint about `mixing_beta`, `conv_thr` or
  `diagonalization`.
