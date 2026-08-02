# QE Workflow v2 — maintenance log

**Read this before editing `qe.sh`.** It records which bugs are already fixed
(so they are not "fixed" a second time, differently), which limitations are
deliberate, and which are still open. `README.md` next to this file describes
what the workflow *does*; this file describes the state it is in.

Last entry: **2026-08-02**, synced to the cluster the same day. Running
`qe.sh` version: see `md5sum qe.sh` against the table at the bottom.

---

## 0. Which copy is authoritative

These copies exist and they are NOT all in sync:

| Copy | State |
|---|---|
| `QE_automation/` on the cluster | **authoritative** |
| laptop `~/QE_automation/` | mirror of this one, added 2026-07-27. `qe.sh`, `config.sh` and `lib/` are byte-identical to the cluster's and must stay that way (§1.6) — it is a deployment, not a fork. Local runs live in `cases/`. |
| the v1 directory beside it | v1, twelve files, **retired 2026-07-27**. Everything it did is in the current layout, including `script/check_job.sh` which came back as the `check` step (§1b). Kept only as a historical reference: it still has the vc-relax cell bug of §1.1 and none of the fixes below. Do not run it and do not develop there. |
| this repository | up to date as of 2026-07-27 (PRs #1 and #2). Code files identical to the cluster's; **only `MAINTENANCE.md` differs**, and only in §5, which is generalised there because the repo is public. Never publish the account or folder names from §5. |

If a future session is asked to "fix the QE workflow", check which of these the
files being looked at belong to before changing anything.

`SETUP.md` next to this file is the third document: the user-facing checklist
of what an input must satisfy to be accepted. It was written by *testing* each
requirement rather than reading the code — which is how §1.7 was found — so
keep it in step with the validation in `step_parser()` whenever that changes.

---

## 1. Fixed — do not re-fix

### 1.1 vc-relax discarded the relaxed cell (fixed 2026-07-27)

`step_extract()` read `ATOMIC_POSITIONS` from `$RELAX_OUT` but
`CELL_PARAMETERS` from **`$RELAX_IN`**. For `calculation='vc-relax'` every
later step (scf, bands, nscf, dos) therefore ran on the *input* cell holding
the *relaxed* positions — a structure that was never optimised, reported by
nothing. It also made the pipeline's "relaxed lattice constant" equal to the
input value by construction, which is why README's graphene verification
reported exactly 2.460 Å, its own input.

Now: `extract_final_cell()` reads the `CELL_PARAMETERS` block inside
`Begin final coordinates` of the relax output, and `step_extract()` falls back
to the input cell only when the output has none. A plain `relax` legitimately
has none — the cell does not move — so the fallback is correct there and is
not a workaround. When `calculation` starts with `vc-` and the block is still
missing, it warns loudly instead of falling back in silence.

`extract_final_cell()` also converts a `CELL_PARAMETERS (alat= <bohr>)` header
to angstrom, because pw.x will not read that numeric-alat form back.

`step_extract()` now prints which source each half of the structure came from:

    cell     : relaxed cell from gra_relax.out
    positions: relaxed positions from gra_relax.out

If a future run prints `cell : input cell from ...` for a vc-relax, something
regressed or the relax did not converge — check before trusting the numbers.

**The same bug is still present in `../QE_workflow/script/extract_structure.sh`
(v1).** Left alone on purpose: v1 is frozen. Do not "discover" it there and
patch v1 into a fourth divergent version.

### 1.2 The parser dropped every &SYSTEM key it did not know (fixed 2026-07-27)

`get_param()` reads 16 named keys. Everything else the input declared was
silently absent from the generated scf/band/nscf inputs: `nbnd`, `nspin`,
`starting_magnetization`, `vdw_corr`, `tefield`/`dipfield`, `edir`,
`tot_charge`, `input_dft`, `assume_isolated`, ...

Concretely, for the MoS2 gas-sensor project: an input with
`vdw_corr = 'DFT-D3'` produced an SCF **without** dispersion correction, and
the `nspin=2` NO2 input produced a **non-magnetic** band structure. No error,
no warning, different physics — the same failure mode as the `nbnd = 120` bug
recorded in `../mos2/README.md`.

Now: `namelist_passthrough()` copies every remaining line of `&CONTROL`,
`&SYSTEM` and `&ELECTRONS` through to the generated inputs as raw text, so
indexed keys (`starting_magnetization(1) = 0.5`) and keys this script has
never heard of survive unchanged. What is deliberately dropped:

- `DROP_CONTROL` — `calculation`, `prefix`, `outdir`, `pseudo_dir` (generated
  here), plus `restart_mode`, `nstep`, `etot_conv_thr`, `forc_conv_thr`
  (relax-only; `restart_mode` would make a fresh scf try to restart).
  `tefield`/`dipfield` are **not** dropped — they pair with `edir`/`emaxpos`/
  `eopreg`/`eamp` in `&SYSTEM`, and keeping only half of that pair turns the
  dipole correction off without saying so.
- `DROP_SYSTEM` — the eight keys the generator writes itself, plus
  `celldm`/`A`/`B`/`C`/`cosAB`/`cosAC`/`cosBC`: the lattice now comes from
  `cache/structure.in` as an explicit `CELL_PARAMETERS` card, and a second
  stale definition of the same cell in `&SYSTEM` is how the two disagree.
- `DROP_ELECTRONS` — `conv_thr`, `mixing_beta`.

`&IONS` and `&CELL` are not passed through at all: they mean nothing for scf,
bands or nscf. `cell_dofree` is still read separately by `get_param`, because
the nscf k-mesh scaling needs it.

The parser prints what it carried over, e.g.

    passthrough &SYSTEM: nbnd nspin starting_magnetization(1) vdw_corr edir

If a future run of a MoS2-plus-gas input does **not** print `vdw_corr` on that
line, the passthrough regressed.

### 1.3 parser.cache is versioned (added 2026-07-27)

`parser.cache` gained `CONTROL_EXTRA` / `SYSTEM_EXTRA` / `ELECTRONS_EXTRA`. A
cache written by an older `qe.sh` has none of them, and sourcing it would run
with the passthrough empty — indistinguishable from §1.2 being broken.

`CACHE_VERSION_EXPECTED` (currently `3`) is compared against the
`CACHE_VERSION` in the cache; on mismatch `require_cache()` re-runs the parser
automatically and says so. **Bump `CACHE_VERSION_EXPECTED` whenever a field is
added to the cache**, or stale caches will be sourced silently.

The name is deliberately different from `CACHE_VERSION` because sourcing the
cache would otherwise overwrite the value it is being compared against.

### 1.4 Cards other than the four built here were dropped (fixed 2026-07-27)

§1.2 fixed the namelists; the cards had the same hole. QE 7.x writes DFT+U as
a **HUBBARD card**, not as `&SYSTEM` keys, so a NiO-style input relaxed with
`U Ni-3d 5.0` produced an scf, band and nscf with no U at all — an
antiferromagnetic insulator comes out metallic, silently.

`extract_cards()` now carries `HUBBARD` and `OCCUPATIONS` (`CARDS_KEPT`)
through to every generated input, appended after `K_POINTS`. Card order is
free in QE, which is why the generators call `emit_extra_cards` last rather
than folding it into `emit_pw_input`.

`CONSTRAINTS`, `ATOMIC_VELOCITIES` and `ATOMIC_FORCES` are deliberately *not*
carried: they only mean something to a relax or an MD run.

Note for the laptop: QE **6.7 does not have the HUBBARD card** at all (added
in 7.1). On that version DFT+U is `lda_plus_u` + `Hubbard_U(i)` in `&SYSTEM`,
which the §1.2 namelist passthrough already carries. Nothing to do — but do
not "fix" the card passthrough because 6.7 rejects it.

### 1.5 K_POINTS: gamma-only worked nowhere, and bad forms failed at step 9 (fixed 2026-07-27)

Two separate problems in one card.

The parser only ever read the line *after* the `K_POINTS` header. A molecule
using `K_POINTS {gamma}` has no such line, so it was rejected with
`K_POINTS block not found` — a message pointing at a card that was right
there. Isolated molecules could not be run at all.

And an explicit k-point list (`K_POINTS crystal`, `tpiba`, ...) parsed fine,
then aborted in `step_gen_nscf` — **step 9 of 11**, after the relax, scf, band
and bands.x steps had already run. A wrong k-point card cost hours before
saying so.

Now `K_POINTS_MODE` is read from the header word and validated in the parser,
step 1:

- `automatic` — the mesh line must parse as `nk1 nk2 nk3`; scaled for nscf.
- `gamma` — reproduced verbatim, nscf does not scale it (there is no mesh),
  and `NPOOL` must be 1 because one k-point cannot be split across pools.
- anything else — rejected in seconds, with the reason and what to use.

### 1.6 One script for the cluster and the laptop (2026-07-27)

`load_modules()` hardcoded four `module load` lines, so `qe.sh` could only run
where Lmod and those exact modules existed. The obvious move — a separate
laptop copy — is precisely the mistake §0 is about, so instead:

- `qe.sh` detects whether `module` exists (as a *function* as well as a
  binary; on Lmod it is a shell function, so `command -v` alone misses it).
  Without it, pw.x is taken from PATH. Either way it verifies pw.x is actually
  resolvable and says so clearly if not.
- The module list moved to `QE_MODULES` in `config.sh`, which is settings, and
  is empty on a machine with no `module`.
- `NPROC` comes from `SLURM_NTASKS` under Slurm, otherwise from the
  **physical core count**. Not `nproc`: that reports hyperthreads (12 on a
  6-core laptop) and Open MPI counts a slot per core, so pw.x refused to start
  with `not enough slots available in the system`. An SMT sibling is not a
  second FPU either, so oversubscribing would only have been slower.
- `NPOOL` is clamped to the largest divisor of `NPROC` not exceeding
  `NPOOL_WANTED`, because a fixed `NPOOL=4` aborts on any core count it does
  not divide.

`qe.sh` and `config.sh` are therefore **byte-identical on both machines** —
verify with `md5sum`, and if they ever differ, that is a bug, not a
configuration. `ulimit -l unlimited` is now best-effort: locking memory is a
cluster privilege and a laptop refusing is not a reason to stop.

### 1.7 Two input-format traps closed (2026-07-27)

Found while writing `SETUP.md`, by testing the requirements rather than
assuming them:

- **`ibrav` was never required.** Omitting it emitted a bare `ibrav =` into
  every generated input, and pw.x failed on a namelist read three steps later
  with nothing pointing at the cause. `IBRAV` joined `NAT`/`NTYP`/`ECUTWFC` in
  the required list, and `ibrav /= 0` is now rejected in the parser too —
  previously it got as far as `step_extract` before failing on the missing
  `CELL_PARAMETERS`.
- **`ATOMIC_SPECIES` was terminated only by a blank line.** An input whose
  species card ran straight into `ATOMIC_POSITIONS` had the whole positions
  card swallowed into the species list, and the generated inputs carried a
  mangled `ATOMIC_SPECIES`. It now stops at a blank line *or* any card header
  (`CARDS_ALL`), so the blank line is no longer load-bearing.

### 1.8 Earlier fixes, already described in README.md

Recorded here only so they are not re-litigated: `config.sh` no longer
overwrites input values (`DEFAULT_*` namespacing); the band k-path is per case
and never guessed; `smearing`/`degauss` are required only under
`occupations='smearing'`; the nscf k-mesh respects `cell_dofree`; `NPOOL`
(`-nk`) is what actually fixed `wrong record length`, not the pseudopotential
family. See README.md §"What changed from v1" for the reasoning.

---

## 1a. What kinds of material actually work

Audited 2026-07-27 by running every non-MPI step over a matrix of inputs
chosen to be unlike graphene and MoS2 (`audit` cases: cubic semiconductor,
magnetic bcc metal, DFT+U antiferromagnet, isolated molecule, explicit
k-list, ibrav /= 0). Result:

| Input | Works | Why |
|---|---|---|
| 2D hexagonal slab (graphene, MoS2, WS2) | yes | the original target; `cell_dofree='2Dxy'` keeps k_z = 1 |
| 3D bulk, any Bravais lattice, `ibrav = 0` | yes | nscf scales all three directions when the cell is not declared 2D |
| Insulator / semiconductor, `occupations='fixed'` | yes | smearing/degauss correctly not emitted |
| Metal with smearing | yes | |
| Spin-polarised (`nspin=2`, `starting_magnetization`) | yes | via §1.2 |
| Dispersion-corrected (`vdw_corr`) | yes | via §1.2 |
| DFT+U, QE 7.x `HUBBARD` card | yes | via §1.4 |
| DFT+U, QE 6.x `lda_plus_u` in &SYSTEM | yes | via §1.2 |
| Multi-species (3+ `ntyp`) | yes | |
| Isolated molecule, `K_POINTS gamma` | yes, `NPOOL=1` | via §1.5 |
| **`ibrav /= 0`** (celldm / A,B,C) | **no** | needs an explicit `CELL_PARAMETERS` card to extract; fails loudly at `extract` |
| **Explicit k-list** (`K_POINTS crystal`/`tpiba`) | **no** | no mesh for the nscf step to scale; now rejected in step 1 |

The two "no" rows fail with a message naming the cause and the fix. Neither is
silent, and neither is worth supporting until a real case needs it: `ibrav=0`
is what all this project's inputs use, and the nscf step exists to densify a
mesh.

**The one thing nothing can check for you:** `<case>_band.path` is required,
but nothing verifies the path suits the lattice. Handing a cubic material the
hexagonal example produces a band structure along a meaningless path, with no
error — see §2. That is the residual risk when moving to a new material.

## 1b. Layout: why lib/, and how to add a stage

v1 was eleven files, v2 collapsed them into one, and this is the third shape:
a thin `qe.sh` plus `lib/`. That is not a swing back to v1 — the two things
that made v1 wrong are still gone.

What actually broke v1 was never the file count:

- each helper was launched with `bash -c`, i.e. its own login shell, which
  re-sourced `/etc/profile` and swapped `mpirun` for one that could not launch
  an Intel-MPI-linked `pw.x`;
- each helper sourced `config.sh` on its own, in its own order, so
  `generate_scf.sh` escaped the clobbering of §"config.sh no longer overwrites
  your input" in README while `generate_band.sh` and `generate_nscf.sh` did
  not;
- the three generators duplicated ~225 lines, and duplication in separate
  files is duplication you cannot see.

`lib/` keeps all three fixed: the files are **sourced**, once, into one
process — one environment, one `config.sh`, one `emit_pw_input()`. What comes
back is only the browsability: ~80-390 lines per file, one concern each.

    qe.sh              orchestrator: paths, config, the step registry, dispatch
    lib/common.sh      environment, per-case paths, diagnostics, step_check
    lib/parser.sh      reading the relax input into cache/parser.cache
    lib/structure.sh   pulling the relaxed geometry out of the relax output
    lib/generate.sh    writing the scf / band / nscf inputs
    lib/run.sh         the steps that launch pw.x, bands.x, dos.x
    lib/init.sh        lattice classification + band path (§1c)
    lib/plot.sh        band / DOS figures from the finished data (§1.10)

**Adding a stage** (work function, PDOS) is now two edits, not four:

1. write `step_<name>()` in whichever `lib/` file it belongs to
2. add `<name>` to `PIPELINE_STEPS` in `qe.sh`, where it runs

The step numbers (`3/11`) are counted from that list, so nothing needs
renumbering, and there is no second list of step names to keep in sync — the
old `run_one_step()` and the validation `case` both enumerated them, and
forgetting the second gave "unknown step" for a function that existed.
Dispatch is `name -> step_<name>` with dashes mapped to underscores, and
`qe.sh` checks at startup that every registered name has a function behind it.

`step_check` is v1's `script/check_job.sh`, restored. Merging into one file
had turned `check_done`/`diagnose_failure` into internals reachable only
mid-run, which lost the ability to ask "what happened?" of a case that
finished hours ago. `qe.sh check <case>_relax.in` now reports every stage.

### 1.9 The hexagonal template pointed at the wrong K (found 2026-07-27)

`template/band.path.hexagonal_example` used **K = (1/3, 1/3, 0)**. That is
correct only for the γ = 120° hexagonal setting. Every hexagonal cell in this
project uses γ = 60°:

    a1 = (a, 0, 0)
    a2 = (a/2, a√3/2, 0)      -> γ = 60°

The two settings are the same lattice but not the same reciprocal basis, so
the fractional coordinates of K differ. Measured on the graphene test cell
(a = 2.46 Å, |K| must be 4π/3a = 1.70276):

    (1/3, 1/3, 0)   |k| = 0.98309   <- inside the zone, not K
    (2/3, 1/3, 0)   |k| = 1.70276   <- K
    (1/3,-1/3, 0)   |k| = 1.70276   <- K, equivalent

Proof from the band data rather than the geometry. Two bands nearest E_F at
the point labelled "K", graphene:

    with (1/3,1/3,0)   -6.9769 and 2.5639 eV   -> 9.54 eV apart
    with (2/3,1/3,0)   -2.3473 and -2.3473 eV  -> degenerate, at E_F exactly

The Dirac point — the one feature of graphene everyone knows — was absent
from the workflow's own verification band structure, and nothing said so. The
DOS route is computed on a uniform mesh, so it showed the Dirac point
correctly all along; that is why the README's cross-check passed while the
band path was wrong.

**Scope: the template, and the test cases that copied it. Not the research
data.** `mos2/band/*.nscf.in` and the WS2 runs use
`(0.125, 0, 0)` and `(1/12, -1/12, 0)` — the γ = 60° K, scaled by 1/4 for the
4×4 supercell. Those were written by hand and are correct. What was wrong is
the template the workflow shipped, which is what a new material would have
been given.

Fixed by `step_init` (§1c): the lattice is measured, the setting is detected
from γ, and the matching path is written. The template is now two files named
for their setting — `band.path.hex_gamma60_example` and
`band.path.hex_gamma120_example` — so a hand-written path is a choice, not a
coin flip.

### 1c. `qe.sh init` — the band path is derived, not copied

Copying a template was the last step where a user could silently do the wrong
thing (§1.9). `step_init` reads `CELL_PARAMETERS`, computes a, b, c, α, β, γ,
classifies the Bravais lattice, and writes `<case>_band.path`.

This is not the "apply one path to everything" bug of README §3 returning:

- the lattice is **measured**, not assumed;
- the classification and the numbers behind it are **printed**, so a wrong
  guess is visible before anything runs;
- a cell that does not classify is **refused**, with instructions to write the
  path by hand — never given a default;
- an existing `<case>_band.path` is never overwritten, so a hand-written path
  wins.

Recognised: hexagonal (γ=60 and γ=120), simple cubic, FCC, BCC, tetragonal,
orthorhombic — the last two and hexagonal each in a 3D and a 2D-slab variant.

The `orc_2d` / `tet_2d` variants were added 2026-07-29, when phosphorene from
the CMPT Tohoku tutorial (orthorhombic, c/a = 7, i.e. 23 Å of vacuum) came out
as plain `orc` and got a path that spent four of its nine segments walking k_z
through that vacuum. The `c/a > 2` slab test already existed for hexagonal;
it simply had not been applied to the other two right-angled classes. Tolerances are 0.1% on lengths and 0.5° on
angles — a relaxed cell is never exact, but 1%/1° was too loose: it classified
BaTiO3 (a=3.99, b=4.01, c=4.03) as simple cubic. 2D is `c/a > 2`, which drops
k_z from the path; sampling k_z of a vacuum gap is wasted work.

Adding a lattice: one `case` arm in `band_path_for()` and one branch in the
awk classifier in `lib/init.sh`.

### 1.10 `qe.sh plot` — figures, added 2026-07-29

`lib/plot.sh` closes the pipeline: `<case>_band.png`, `<case>_dos.png`, and
the two side by side sharing one energy axis. It is the 12th and last entry in
`PIPELINE_STEPS`.

Everything it needs is already on disk when it runs, so it launches no MPI and
can be re-run on a case that finished months ago — including on a laptop
against a case folder copied down from the cluster:

    <prefix>.bands.dat.gnu   bands.x   blank-line separated blocks, one per band
    <prefix>.dos             dos.x     3 columns, or 4 when nspin=2
    <case>_bandsx.out        bands.x   "x coordinate" of each high-symmetry point
    <case>_band.in           gen-band  the "! G" comments = the tick labels
    <case>_scf.out           scf       the Fermi energy

Four decisions worth not re-litigating:

1. **It writes a script and runs it, rather than drawing directly.** The
   `<case>_plot.py` / `.gnu` it leaves behind has a settings block at the top
   and is meant to be edited and re-run on its own. A figure always needs
   tuning for a specific paper, and that tuning must not require touching
   `lib/`. Re-running `qe.sh plot` overwrites the script — noted in `SETUP.md`.

2. **Tick positions come from `bands.x`, labels from `<case>_band.in`.** The
   path file holds fractional coordinates; the plot's x axis is distance
   travelled through reciprocal space, and `bands.x` is the only thing that
   has already done that conversion. The labels come from the `.in` rather
   than the `.path` because the `.in` is what `bands.x` actually saw — editing
   the path file after a run would otherwise relabel data it does not
   describe. When the two counts disagree the ticks are **numbered**, not
   guessed at; putting a name on the wrong k-point is exactly the failure
   §1.9 and §1c exist to prevent.

3. **The zero comes from the NSCF run** — see §1.11, which is the correction
   to what this point originally said. When `occupations='fixed'` QE prints
   band edges instead of a Fermi level, and the highest occupied level is
   used. Whichever source was taken is named in the step's output, so it is
   never silent about which it took.

4. **It is fail-soft: it returns success even when it draws nothing.** It is
   the last step of a pipeline that may have run for hours, and a compute node
   without matplotlib is not a reason to mark a finished calculation as
   failed. Every failure is printed in full, so this is non-fatal, not silent.
   `PLOT_ENGINE="none"` in `config.sh` turns it off quietly.

Verified on the two cases in `cases/`, both engines, figures inspected:

    gra_fix     Dirac cone lands exactly on K at E - E_F = 0, DOS -> 0 there
    mos2unit    gap and band edges as expected for a monolayer

The 4-column spin-polarised DOS branch was checked against a synthetic
`pwscf.dos` (no `nspin=2` case has run through this workflow yet), both
engines: up plotted positive, down negative, axis symmetric.

### 1.11 The plot zero came from the wrong run (fixed 2026-07-29)

`plot_fermi_energy()` read the Fermi level from the **SCF** output. §1.10
point 3 above justified that: the band run and the NSCF run are both
non-self-consistent restarts of one SCF charge density, so the SCF looked
like "the" common reference.

That conflated two different quantities. The eigenvalues do all come from the
same charge density — but the Fermi level is not read off the density. It is
found by integrating occupations over the k-point mesh, and the SCF mesh is
not the NSCF mesh. `NSCF_KPOINT_SCALE=2` means the NSCF mesh is deliberately
the denser of the two, so its E_F is the better estimate. It is also the value
`dos.x` writes into the DOS header, so the old order had the band panel on one
zero and the DOS data on another.

On a semiconductor the coarse SCF E_F can land **outside the gap**, which puts
the zero line through a band instead of between them:

    phosphorene   VBM -2.1345   CBM -1.4888   (gap 0.646 eV)
      E_F scf  (6x6x1)    -2.2887   below the VBM  -> band top stuck out
                                                      ABOVE the zero line
      E_F nscf (12x12x1)  -2.0755   inside the gap

    silicon       VBM  6.2102   CBM  6.7831   (gap 0.573 eV)
      E_F scf  (6x6x6)     6.7922   just above the CBM
      E_F nscf (12x12x12)  6.7489   inside the gap

Silicon had the same fault first, in the other direction and only 43 meV, so
nobody caught it. Phosphorene's 213 meV made it visible: the valence band
poked above the dashed line, which is what a reader notices.

Order is now nscf output -> DOS header -> scf output, and falling through to
the SCF prints a warning saying why. Found by a reader of the phosphorene
figure, not by the workflow — worth remembering that nothing here checks that
E_F lands in a gap, because doing so needs an electron count the plot step
does not have.

For a gapped material the robust reference is the **VBM**, not E_F at all:
E_F under smearing sits wherever the occupation integral puts it, which is
near a band edge rather than mid-gap. Setting `E_FERMI` to the VBM in the
generated plot script is the right move for a figure meant for publication.

### 1.12 A folder of cases, and the four collisions that made it unsafe (2026-08-02)

`qe.sh <folder>` now stands for every `*_relax.in` inside it, in name order —
the `run.sh` convention from the cluster, without the hand-written file list
that goes stale. Non-recursive on purpose: `qe.sh cases` must not become a
full-week accident.

Adding it exposed four things that were **already broken** and only invisible
because one folder had held one material:

1. **`cache/parser.cache` and `cache/structure.in` were per folder.** Three
   cases in one folder wrote the same two files, last one wins. A full
   pipeline survived it by accident (each case parses and immediately consumes
   its own cache), but `qe.sh parser <folder>` followed later by
   `qe.sh gen-scf <folder>` would have written all three scf inputs from the
   last case's parameters, silently. Now `<case>.parser.cache` and
   `<case>.structure.in`.
2. **An absent `prefix` defaulted to `pwscf`.** `bands.x`/`dos.x` name their
   output after the prefix, so every case produced one `pwscf.dos`. It now
   defaults to the case name. `SETUP.md` used to carry "one material, one
   folder" as a rule to remember; deriving the prefix removes the rule.
3. **An explicit shared `prefix` still collides**, and no default can fix that
   — so `qe.sh` refuses to start, naming both files. Checked with the parser's
   own `get_param()`, not a second grep: two readers of one key is the
   divergence this project keeps having to repair.
4. **`logs/status.tsv` and `logs/pipeline.out` were per folder** for the same
   reason. Now per case.

Migration, to be deleted when no old folders are left: `require_cache()`
re-parses when it finds a legacy `cache/parser.cache`, and `step_plot()` falls
back to `pwscf.*` data — out loud in both cases. `cases/mos2`, `cases/si` and
`cases/phosphorene` are folders in that state.

**One thing the shims do not cover.** A folder written by the old layout holds
`work/pwscf.save`, while a regenerated `<case>_scf.in` now asks for
`work/<case>.save`. Redrawing figures is fine — that is what the `plot`
fallback is for — but re-running `band` or `nscf` on such a folder without
re-running `scf` first will not find the charge density. Re-run from `scf`, or
delete `work/` and run the pipeline. Nothing is lost either way: the `.out`
files and the `pwscf.*` data are never touched.

### 1.13 Where a killed run got to (2026-08-02)

A job killed by the scheduler gets SIGKILL, which no trap can catch. The log
just stopped mid-sentence, hours of pw.x output away from the last step
header, and for a multi-case run the summary never printed at all.

`logs/<case>.status.tsv` records each step **before** it starts, so a RUNNING
line with nothing after it *is* the interruption, however violent the death.
`qe.sh check` reads it and says which of the twelve steps was in flight, when
it started, and what to run to find out why. Traps on TERM/INT add a message
when the signal is catchable; the EXIT trap records a step that ended with
`exit 1`, which is how most step functions report failure — a `return`-based
scheme would have missed all of them.

Appends rather than truncates: re-running `plot` to redo a figure must not
erase the record of the twelve-step run that produced the data. Only the block
after the last `# run` line is reported.

The traps are installed **inside** the per-case subshell. Bash resets a
parent's traps in a subshell, so an EXIT trap set outside would never fire for
the step that actually failed. Verified before relying on it.

### 1.14 The exit code was always 0 (2026-08-02)

`FAILED` was set on a failing case from the day multi-case support was written
and then never read — the script's last command was the wall-time `echo`.
`README` promised "exit code 1 if any failed"; `sacct` showed `COMPLETED 0:0`
for a job half of whose cases had died, and `sbatch --dependency=afterok`
would have launched the next stage on it. Now `exit "$FAILED"`, and the
summary names the step each failed case stopped at.

### 1.15 `get_param()` kept the trailing comment (2026-08-02)

`ecutwfc = 60   ! Ry, converged` parsed to the value `60   ! Ry converged` —
not even the text as written, since the quote rule had eaten the comma — and
was copied into every generated input. Fortran namelist reads tolerated it, so
nothing ever broke; but `qe.sh dump`, which exists to show what the parser
sees, showed the wrong value, and `namelist_passthrough()` already stripped
comments, so the two halves of the parser disagreed about what a line means.

### 1.16 A relax that never converged was reported as SUCCESS (2026-08-02)

`check_done()` looks for `JOB DONE.` and nothing else. pw.x prints it for a
BFGS run that ran out of ionic steps too — it was asked for `nstep` steps and
gave `nstep` steps, so from the program's side nothing went wrong:

    The maximum number of steps has been reached.
    End of BFGS Geometry Optimization
    JOB DONE.

`step_extract()` then took the **last** `ATOMIC_POSITIONS` block in the file —
the final BFGS step, forces still above threshold — and labelled it "relaxed
positions from <case>_relax.out". scf, bands, nscf and dos all ran on a
structure that is not a stationary point, and `qe.sh check` said `SUCCESS`.
Only the `vc-*` branch warned, and only about a missing final *cell*; the
`relax` inputs the MoS2 and WS2 work actually uses had no check at all.

Verified before fixing: a hand-written `.out` with the text above and no
`Begin final coordinates` produced `SUCCESS : nc_relax.out` and a
`cache/nc.structure.in` holding the unconverged geometry.

`assert_relax_converged()` now requires the `bfgs converged in N scf cycles`
line that QE prints for both `relax` and `vc-relax` — confirmed present in all
seven `cases/*/*_relax.out`. Called from `step_relax` (so a full pipeline stops
at 2/12 rather than after the scf) **and** from `step_extract`, because the
relax may have been run outside this workflow: a hand-written `run.sh` on the
cluster, or output copied down from one, which is exactly how the WS2 screening
was run. `step_check` reports it too, under a `NOT DONE:` headline rather than
`SUCCESS` — "SUCCESS" above "NOT CONVERGED" is the mixed message this exists to
remove.

`REQUIRE_RELAX_CONVERGED=0` in `config.sh` downgrades it to a warning and
continues. Default 1.

**Two arithmetic traps in reading that force, both found by real data rather
than by review.** First, compare on the largest force COMPONENT, not on
`Total force`. QE's
criterion is per component ("all components of all forces smaller than
`forc_conv_thr`"); `Total force` is the norm of the whole 3N-vector, larger
than any component by roughly sqrt(3N). The first version of this check
compared the norm and reported phosphorene — four atoms, every component
~0.0007 against a 1.0E-03 threshold, norm 0.002004 — as unconverged. Any cell
with a few atoms would have cried wolf.

Second, stop at the force **decomposition**. QE prints `The non-local contrib.
to forces`, `The core correction contribution to forces` and friends *between*
the force listing and the `Total force` line, each with its own per-atom lines.
Those terms are individually huge and mostly cancel; reading them as forces
reported **37.07 Ry/au** for a production MoS2+NO2 run whose largest real
component was 0.0018. It did not change any verdict - that comes from the
`bfgs converged` line - but it corrupted every number reported alongside it and
would have raised a Pulay warning on converged runs that was pure arithmetic.
The laptop's test outputs happen not to print the decomposition, so this
survived local testing and was caught the first time the code met cluster data.

Side finding, kept as a warning rather than an error: `cases/mos2` converges
(`bfgs converged in 6 scf cycles`) and then QE's `Final scf calculation at the
relaxed structure` — where the G-vectors are recalculated for the new cell —
comes back with a largest component of **0.0137 Ry/au, 13.7x the threshold**.
The structure is converged in the basis it started from and not in the correct
one: Pulay stress. Expected for a test case with a deliberately low cutoff, but
it is the reason a single `vc-relax` is not a converged answer — the remedy is
to re-run it from the final structure until the cell stops moving. Now printed
whenever it happens.

### 1.17 Pseudopotentials are checked before the queue, not by pw.x (2026-08-02)

`step_parser()` checked that a `pseudo_dir` line existed and was not empty.
Nothing checked that the directory was there, or that the `.upf` files named in
`ATOMIC_SPECIES` were in it. pw.x finds that out a few seconds into a job that
may have queued for hours, and `diagnose_failure()` could only explain it
afterwards.

The WS2 screening is why it matters: twenty inputs whose `pseudo_dir` had to be
rewritten by hand when they moved from `ataqiyya` to `ahma080`, where one
missed line costs a whole queue wait to discover. With folder mode it
multiplies - ten cases in a folder, ten failures in a row.

Checked in the same preflight pass as the prefix collision, for every case
before the first one starts, so a folder of ten is fixed in one go rather than
one queue wait at a time.

**Fatal only for the steps that launch pw.x** (`MPI_STEPS`, plus `all`).
Preparing inputs on a laptop is normal, and there `pseudo_dir` names a cluster
path that is *supposed* to be absent; refusing `qe.sh dump` or `qe.sh gen-scf`
over it would make the tool an obstacle where it is meant to help. Those steps
print a note and carry on.

A relative `pseudo_dir` resolves against the directory holding the input,
because that is where `run_pw()` cd's to - not against wherever `qe.sh` was
invoked from.

`atomic_species_block()` was factored out of `step_parser()` for this: the
preflight needs the same card before any step runs, and two readers of one card
would eventually disagree about where it ends.

### 1.18 `qe.sh <folder>` was read as a step name (fixed 2026-08-02)

Found by testing the documented form after writing it. The step-vs-input test is

    if [[ "$1" != *_relax.in ]]; then STEP="$1"; shift; fi

and a directory does not end in `_relax.in` either, so `qe.sh cases/gra` - the
bare form README and SETUP.md both give as *the* way to use folder mode - set
`STEP="cases/gra"`, shifted the only argument away, and died with "no input
file given". Every test written for §1.12 had passed an explicit step name
(`qe.sh parser cases/gra`), so none of them touched it.

Now a directory is treated as an input unless it is also a known step name.

### 1.19 bands.x wrote spin up only for nspin=2 (fixed 2026-08-02)

bands.x writes ONE spin channel per run and `spin_component` defaults to 1.
`step_bandsx()` never set it, so for a spin-polarised case the band figure
showed spin up only - while the DOS panel beside it showed both channels,
because dos.x writes both without being asked. The two halves of
`<case>_band_dos.png` described different calculations and nothing said so.

This sat in §3 as an open item with the note "not hit yet: no nspin=2 case has
gone through this workflow". That is no longer true, and by a wide margin:
**30 of the project's own 104 production inputs have `nspin = 2`** - the NO2
adsorption cases, where the spin splitting is the physics being reported. (The
same sweep found all 104 use `vdw_corr = 'DFT-D3'`, which is what §1.2 rescued,
and all 104 use ONCV, so the 4x default ecutrho is correct for every one of
them.)

Now `step_bandsx()` runs bands.x once per channel when `NSPIN=2`:

    <prefix>.bands.up.dat   spin_component = 1   <case>_bandsx_up.{in,out}
    <prefix>.bands.dn.dat   spin_component = 2   <case>_bandsx_dn.{in,out}

`lib/plot.sh` draws both, in the two colours the DOS panel already uses - up
solid, down dashed - with a key, and warns when only the up file is present
(which is what every magnetic case produced before this).

**Unpolarised runs are untouched**: same single pass, same
`<prefix>.bands.dat`, same `<case>_bandsx.out`. Existing cases and their
finished data keep working, verified against all seven in `cases/`.

`noncolin` takes the single-pass path: the channels are not separable there and
`spin_component` means nothing to bands.x.

`plot_collect_ticks()` falls back to `<case>_bandsx_up.out` for the tick
positions; without that the magnetic cases lost their k-point labels and fell
back to numbering them.

`nspin` and `noncolin` are now named fields in `parser.cache` (CACHE_VERSION 4)
because step_bandsx has to *know*. They are deliberately NOT added to
DROP_SYSTEM - they still flow to the generated inputs through the §1.2
passthrough, and dropping them there would remove them from the calculation.
Verified: `mag_scf.in` still carries `nspin = 2` and
`starting_magnetization(1) = 0.3`.

### 1.20 Derived files could be older than their sources (fixed 2026-08-02)

Steps hand state to each other through files, and no step checked whether the
thing it was reading had been superseded. Measured before the fix:

    ecutwfc = 60 in the input   ->  <case>_scf.in says 60      correct
    (edit the input to 120)
    qe.sh gen-scf               ->  <case>_scf.in says 60      stale, silent

Exit 0, "SCF input generated", no note. That is precisely the loop README
recommends for debugging - run one step, look, fix the input, run again - so
the recommended workflow was the one that broke.

Once stated as "nothing derived may be older than what it came from", it is
four cases, not one:

| source | derived | before |
|---|---|---|
| `<case>_relax.in` | `cache/<case>.parser.cache` | stale, silent |
| `<case>_relax.out` | `cache/<case>.structure.in` | stale, silent |
| cache + structure | `<case>_scf.in`, `<case>_nscf.in` | stale, silent |
| cache + structure + `<case>_band.path` | `<case>_band.in` | stale, silent |

The last is the dangerous one: fix the k-path, run `band` without `gen-band`,
and pw.x walks the OLD path. A clean band structure of the wrong thing, which
is the failure README section 3 exists to prevent - reintroduced through a
different door.

**Internal state regenerates; generated inputs refuse.** `cache/` holds nobody's
hand-written file and re-reading costs nothing, so `require_cache()` re-parses
and `require_structure()` re-extracts, each saying so. The `<case>_*.in` files
sit next to the input and are plausibly hand-tuned, so `step_scf`/`step_band`/
`step_nscf` stop and name the command to run rather than overwriting work.

Hand-edited generated inputs still run: the edit makes the file the newest
thing there, so the check does not fire. Verified - an `nbnd = 200` added by
hand to `<case>_scf.in` survives and the step proceeds.

mtime, not checksums: no extra state to keep, and "strictly newer" means files
written inside the same second do not trip it, which keeps a fast pipeline
quiet.

### 1.21 No `--time`, and the partition was invisible (fixed 2026-08-02)

The `#SBATCH` header had no `--time` at all, so the walltime was whatever
default the partition carries - set by the cluster admins, absent from this
file, and free to change without notice. A job that passes it is SIGKILLed;
§1.13 explains what that looks like from the inside.

The project's own hand-written `run.sh` for WS2 sets `--time=3-00:00:00`
explicitly, so the risk was already understood there and only `qe.sh` was
missing it. The header also says `--partition=short` while the MoS2 and WS2
work runs on `medium-small`, which means a bare `sbatch qe.sh` gets neither the
partition nor the limit those jobs actually use.

Now `--time=24:00:00` is written down, deliberately modest and documented as a
starting point rather than a recommendation, and the run header prints the
partition and limit the scheduler is really enforcing (`squeue -h -j $JOBID -o
'%P|%l'`) so the number is on the first screen of the log. Sizing per job is
done on the command line - flags beat `#SBATCH`, and this file must stay
byte-identical across the three copies:

    sbatch -p medium-small -t 3-00:00:00 qe.sh cases/ws2_TS

Ten WS2 cases at ~6.5 h each is ~65 h against a 72 h cap - worth watching, and
now visible rather than assumed.

### 1.22 `cif` — the structure as a file you can open (added 2026-08-02)

A new step between `extract` and `gen-scf`, writing two files per case:

    <case>_initial.cif    the geometry as written in <case>_relax.in
    <case>_relaxed.cif    the geometry pw.x converged to

Both come from data the workflow already had - the input, and the
`cache/<case>.structure.in` that `step_extract()` produces - so it reads no
wavefunctions, needs no MPI, and runs on a finished case at any time. In the
pipeline it costs milliseconds.

**Symmetry is P 1, always.** Guessing a space group from relaxed coordinates is
how a CIF comes out subtly wrong with nothing to say so, and every viewer worth
using re-detects symmetry itself with a tolerance the user can see. Same
reasoning as the band path: refuse to guess rather than produce a
plausible-looking answer.

Units are converted rather than assumed. Every input in this project uses
`CELL_PARAMETERS (angstrom)` with `ATOMIC_POSITIONS {crystal}`, where the job
is a reformat - but the repo is public and README's own verification section
describes converting inputs written for other workflows, so `bohr`, `alat`,
`alat=<n>` and cartesian positions are handled too. Cartesian positions need
the lattice inverted to get fractional coordinates; that is done in the awk
rather than waved away.

`crystal_sg` positions are refused: they are symmetry-generated, and expanding
them is exactly the guessing this step avoids.

Species labels are QE's, not CIF's: `Mo1`, `S_up`, `Fe2` all mean an element
plus a tag. Everything from the first digit or underscore on is dropped for
`_atom_site_type_symbol`, and the per-element index is regenerated. `if_pos`
constraint flags trailing a position line are ignored.

Verified beyond "it produced a file": the emitted cell lengths, cell volume and
cartesian interatomic distances were reconstructed from the CIF in numpy and
compared against `cache/mos2.structure.in` - agreement to 1e-8 A. The three
unit paths (cartesian angstrom, cartesian bohr, bohr cell) were round-tripped
from known fractional coordinates and come back exact. A 51-atom WS2+NO2 input
gives `W16 S32 N1 O2`.

`step_cif` is fail-soft per file: a case whose relax has not finished still
gets its initial CIF, and says why the relaxed one is missing.

## 2. Deliberate, not bugs

- **`CASES_PARALLEL > 1` is experimental and slower here** (45–51 min vs 3 min
  sequential for the same work). Cause not pinned down. Do not switch the
  default without timing it again.
- **`bands.x` gets the same `-nk` as `pw.x`.** Post-processing must use the
  pool layout of the run that produced the wavefunctions. `dos.x` gets none.
- **`<case>_band.path` is required, never defaulted.** A hexagonal path
  applied to a non-hexagonal cell produces a wrong band structure with no
  error at all. `template/band.path.hex_gamma60_example` is a thing to copy, not
  a fallback.
- **`ibrav = 0` with an explicit `CELL_PARAMETERS` card is required.** An
  `ibrav /= 0` input has no cell block to extract; `step_extract()` now says
  so in as many words.

---

## 3. Still open

1. **`nbnd` is never raised for the band/nscf steps.** Whatever the input
   declares is now passed through (§1.2), but if the input declares nothing,
   QE's default (~1.2 × nelec/2) applies and leaves few conduction bands. The
   MoS2 project hit the extreme version of this (`nbnd = 120` against ~430
   electrons). Consider `BAND_NBND` / `NSCF_NBND` knobs in `config.sh`.
2. **No `work/` reset before a stage.** `mos2/band/run_h2s_only.sh` had to add
   `rm -rf work; mkdir -p work` for a GPFS `mkdir` race across 64 ranks; that
   mitigation never made it here. Related: `setup_case()` hardcodes
   `mkdir -p "$INPUT_DIR/work"` even when the input's `outdir` is something
   else (e.g. `work_pristine` in `../mos2/work_function/`).

   This also means a job killed part-way (time limit, scancel) leaves a
   half-written `work/` that the next run reuses. Until this is fixed, clear
   it by hand before re-running a case that was interrupted:
   `rm -rf <case_dir>/{work,cache,logs}`.
3. **PDOS and work function are not implemented.** `projwfc.x`/`pp.x`/
   `average.x` are declared in `config.sh` but never invoked. Work function is
   currently done outside this workflow by
   `../mos2/work_function/run_workfunction.sh`. (Plotting is done — §1.10.)
5. ~~**`bands.x` only ever writes spin-up bands.**~~ Fixed 2026-08-02, §1.19.
4. **The graphene case has no `gra_band.path`.** README's "Verified" section
   describes a full 11-step graphene run, but `../graphene/` holds only
   `gra_relax.in`, so re-running it stops at step 6 until a path file is
   copied from `template/`. `../_v2test/graphene/` has both.

---

## 4. How to verify a change without burning queue time

Every step except the four that launch MPI runs on the login node:

    bash qe.sh parser <case>_relax.in     # writes cache/parser.cache
    bash qe.sh dump   <case>_relax.in     # prints everything the parser read,
                                          # including the three passthrough blocks
    bash qe.sh extract  <case>_relax.in   # needs an existing <case>_relax.out
    bash qe.sh gen-scf  <case>_relax.in
    bash qe.sh gen-band <case>_relax.in
    bash qe.sh gen-nscf <case>_relax.in

A hand-written `<case>_relax.out` containing nothing but a
`Begin final coordinates` block is enough to exercise `extract` and all three
generators. That is how §1.1 and §1.2 were tested before any job was
submitted: a fake output whose final cell differs from the input cell, so the
two sources are distinguishable in `cache/structure.in`.

`_v2test/` in `../` holds the throwaway cases used for the end-to-end runs
(graphene 2 atoms, MoS2 unit cell 3 atoms, and the same MoS2 plus
nbnd/nspin/starting_magnetization/vdw_corr). On the laptop the equivalents are
in `~/QE_automation/cases/`. All are workflow tests, not publishable physics —
the cutoffs exercise the pipeline, they are not converged.

A run does not need the `short` partition. `sbatch -p interactive qe.sh ...`
starts immediately when `short` is full, which it often is.

Two traps with `interactive`, both hit on 2026-07-27:

- Its nodes are **shared**. The same 3-case run took 3m23s on an idle node and
  was still unfinished 40 minutes later once two other users' jobs landed on
  the same node. A slow run there is contention, not a regression — confirm
  with `squeue -w <node>` before suspecting the code.
- Its limit is 2 h and `-t` caps it further. A `-t 00:40:00` cut case 3 of 3
  off mid-relax. Either leave `-t` off, or size it for the *contended* case.

### 4.1 What the 2026-07-27 fixes were actually verified against

Three cases, full 11-step pipeline each, in `../_v2test/`. Submitted to the
`interactive` partition (`sbatch -p interactive -t 00:40:00 qe.sh ...`) because
`short` was 48/48 allocated with a 4.5 h estimated start — worth remembering,
a 3-minute validation does not have to wait for `short`.

    gra        graphene, 2 atoms, PAW, 40 Ry    OK   1m28s
    mos2unit   MoS2 unit cell, 3 atoms, 60 Ry   OK   1m55s
    mos2vdw    as mos2unit + nbnd/nspin/
               starting_magnetization/vdw_corr  OK   ~2m

§1.1, on real output rather than a fixture:

    graphene   input cell 2.460000 A  ->  relaxed 2.465627 A
    mos2unit   input cell 3.180000 A  ->  relaxed 3.182359 A
    mos2vdw    input cell 3.180000 A  ->  relaxed 3.165499 A

Every one of those relaxed values would have been thrown away before the fix,
and the input value used in its place. The `mos2vdw` row is the clearest: the
D3 correction pulls the lattice *in* by 0.017 A relative to the same cell
without it, so the un-relaxed 3.180 was wrong in the opposite direction.

§1.2: all four passthrough keys reached `mos2vdw_{scf,band,nscf}.in`, and QE
acted on them in every stage — `DFT-D3 Dispersion Correction` and
`Starting magnetic structure` in the scf, band and nscf outputs, with
`number of Kohn-Sham states = 40` from the passed-through `nbnd`. Before the
fix all four were dropped after the relax, so the scf ran without dispersion
and without spin polarisation while the relax had both.

Physics cross-check, not just exit codes: graphene DOS crosses zero at
~-2.51 eV against E_F = -2.347 eV (Dirac point of a semimetal); MoS2 unit cell
shows a clean DOS gap 2.31 -> 3.20 eV with E_F = 3.126 eV inside it. That gap
is well under the ~1.6-1.8 eV expected of a PBE MoS2 monolayer because the
test input's c axis is only 12.38 A, i.e. ~6 A of vacuum, so the periodic
images still interact. That is a property of the throwaway test input, not of
the workflow — do not copy those cell settings into real work.

### 4.2 Cluster and laptop agree — but not on the Fermi energy

The same graphene and MoS2 unit-cell cases were run on both machines with the
identical `qe.sh`/`config.sh`: cluster QE 7.2, 64 ranks, 4 pools; laptop
QE 6.7, 6 ranks, 3 pools, no modules.

    graphene relaxed a     cluster 2.465627 A     laptop 2.465626 A
    graphene E_F           cluster -2.3473 eV     laptop -2.3473 eV
    MoS2 relaxed a         cluster 3.182359 A     laptop 3.186743 A
    MoS2 band extremes     cluster -58.804 .. 6.476    laptop -58.824 .. 6.461
    MoS2 DOS gap edges     cluster 2.31 -> 3.20 eV     laptop 2.31 -> 3.16 eV
    MoS2 E_F               cluster  3.126 eV      laptop  2.143 eV

Eigenvalues agree to a few hundredths of an eV across two QE major versions.
**The reported Fermi energy does not, and that is expected**: for a gapped
system with smearing the occupation constraint is satisfied by a whole range
of E_F, so the value is under-determined and each version's bisection lands
somewhere different — 7.2 inside the gap, 6.7 at the valence-band edge. The
occupations, and therefore the physics, are the same either way.

Practical consequence: **do not compare absolute E_F between machines, and do
not align two plots on their reported E_F.** Reference band structures and DOS
to a band edge (the VBM) instead. The same trap is already recorded in
`../mos2/README.md` §5, where the band and DOS routes disagreed on E_F for
this reason.

Timing note: a cluster run that took 3m23s on an idle `interactive` node took
~7x longer when two other users' jobs shared it. `interactive` nodes are
shared; a slow run there is contention, not a regression.

---

## 5. Scope rule (cluster)

The cluster account this runs on is a **shared group account**, with one
subfolder per student plus a shared `pseudo/`. Only ever read, write or delete
inside your own subfolder — everything beside it belongs to someone else.

A second, unrelated account is also reachable over SSH from the same machine.
An old input once pointed `pseudo_dir` at that account by mistake and every
stage aborted with `file ... not found`; if a run dies that way, check
`pseudo_dir` before anything else.

The exact account and folder names are deliberately not written here: this
file is published, and they belong to other people. They are recorded in the
project log on the cluster, and in nothing that gets pushed. **Do not add them
back** — this file has one version, identical on the laptop, the cluster and
GitHub, precisely so there is no "private copy" to drift out of sync.

---

## 6. File versions

| Date | File | md5 | Note |
|---|---|---|---|
| 2026-07-24 | `qe.sh` | `a063a62252fbfe6d163e74b03ce2736a` | v2 as first written; kept as `qe.sh.bak_pre_cellfix_20260727` |
| 2026-07-27 | `qe.sh` | `487139a31a69450aa532672d3e0c026a` | §1.1 + §1.2 + §1.3; kept as `qe.sh.bak_pre_portable_20260727` |
| 2026-07-27 | `qe.sh` | `30b226e204cda8936b84405b8b65a658` | + §1.4 + §1.5 + §1.6; kept as `qe.sh.bak_pre_ibravcheck_20260727` |
| 2026-07-27 | `qe.sh` | `405bc3176044c3ab206eed74a7d91817` | + §1.7; last single-file version, kept as `qe.sh.bak_pre_modular_20260727` |
| 2026-07-27 | `qe.sh` | `8560fe7d6de54b4bb4c97f142b0d37d2` | modular layout (§1b) |
| 2026-07-27 | `lib/common.sh` | `b0e2e159e041ec9c464e14e1e78ae141` | modular layout (§1b) |
| 2026-07-27 | `lib/parser.sh` | `a6abf00c4e45ad53008771c7328b4869` | modular layout (§1b) |
| 2026-07-27 | `lib/structure.sh` | `8ea073e9e8e1739d22a64f1dff56cb46` | modular layout (§1b) |
| 2026-07-27 | `lib/generate.sh` | `5c9b3e9e91b663544b45f9e3edfcf317` | modular layout (§1b) |
| 2026-07-27 | `lib/run.sh` | `e9e1a9ebbedf029434b549212b5bac76` | modular layout (§1b) |
| 2026-07-27 | `config.sh` | `fa06568692f8ca91d82c8a5c2d955f3f` | §1.6; previous kept as `config.sh.bak_20260727` |
| 2026-07-29 | `qe.sh` | `414cd5d5971cbc64a6a18648e064b120` | `init` (§1c) and `plot` (§1.10) registered |
| 2026-07-29 | `config.sh` | `e1258c883ea273d58f35cf927dba9ea9` | + `PLOT_ENGINE` / `PLOT_EMIN` / `PLOT_EMAX` / `PLOT_DPI` / `PLOT_FORMAT` |
| 2026-07-29 | `lib/parser.sh` | `7d71b7e3d4031144ae094e680bf3440f` | §1.4, §1.5, §1.7; `dump` self-parses |
| 2026-07-29 | `lib/generate.sh` | `24593dbbda2328c03fcffe8d7d4e010f` | passthrough + extra cards |
| 2026-07-29 | `lib/init.sh` | `f5f807d05a9fb1e794ef2e3c5441ce40` | §1c, lattice classification + `orc_2d`/`tet_2d` |
| 2026-07-29 | `lib/plot.sh` | `b5769335c90615e588606e91de2924ee` | §1.10 + §1.11 (E_F now from the nscf) |
| 2026-08-02 | `qe.sh` | `5582fd822a0a4c3da1a1db3c72ab9645` | §1.22 `cif` step registered |
| ~~2026-08-02~~ | ~~`qe.sh`~~ | ~~`e121b13419a5973f3405bdf96215f8d0` | §1.21 --time + partition/limit in the header |
| ~~2026-08-02~~ | ~~`qe.sh`~~ | ~~`ec5d5573c0c069c2cad459d4f4a68cad` | §1.17 pseudopotential preflight, §1.18 folder-vs-step |
| ~~2026-08-02~~ | ~~`qe.sh`~~ | ~~`4926762dc73f641428431806fdd786dd`~~ | §1.12 folder mode + prefix preflight, §1.13 status/traps, §1.14 exit code |
| 2026-08-02 | `lib/common.sh` | `38da33a4beaaeef57b0af67756d23bab` | §1.20 freshness checks, auto re-parse / re-extract |
| ~~2026-08-02~~ | ~~`lib/common.sh`~~ | ~~`125669e18d0716e08d4b57467b23f9ec` | §1.19 check scans both bandsx outputs |
| ~~2026-08-02~~ | ~~`lib/common.sh`~~ | ~~`d3b466471d1d255291c6435b9332a5ee` | §1.12 per-case cache/status paths + legacy migration, §1.13 status file, `check` reports it |
| 2026-08-02 | `lib/parser.sh` | `812f3fb82a2b07c95f8d48a4dddea25b` | §1.19 NSPIN/NONCOLIN named, CACHE_VERSION 4 |
| ~~2026-08-02~~ | ~~`lib/parser.sh`~~ | ~~`b6a29b2009048e3264c54b6058f2e1f3` | §1.17 `atomic_species_block()` / `pseudo_problems()` factored out |
| ~~2026-08-02~~ | ~~`lib/parser.sh`~~ | ~~`69b11c268b37168c79db4839a1fed556`~~ | §1.12 prefix defaults to the case name, §1.15 comment stripping |
| 2026-08-02 | `lib/cif.sh` | `b30d33b7d144824901e227dc29ebc5ef` | §1.22 new file |
| 2026-08-02 | `lib/plot.sh` | `ebfcd4ed755ac4145f354419b3f2bea0` | §1.19 both spin channels drawn, both engines |
| ~~2026-08-02~~ | ~~`lib/plot.sh`~~ | ~~`479fb06da5badd09bdb9b1851cfeff7e` | §1.12 `pwscf.*` fallback for folders written by the old layout |
| 2026-08-02 | `lib/structure.sh` | `427f622e0274b5c68941e049fe6100d4` | §1.16 max-force reader stops at the force decomposition (found against cluster data) |
| ~~2026-08-02~~ | ~~`lib/structure.sh`~~ | ~~`babffb0d19d79e39f5718ae8d2db6e00` | §1.16 `assert_relax_converged()` + the max-component force note |
| 2026-08-02 | `lib/run.sh` | `f943975ece275fd6b588297269b9dbbd` | §1.20 scf/band/nscf refuse a stale generated input |
| ~~2026-08-02~~ | ~~`lib/run.sh`~~ | ~~`1ab765b7956a88ae39cb5d4530b49ab7` | §1.19 bands.x once per spin channel |
| ~~2026-08-02~~ | ~~`lib/run.sh`~~ | ~~`2725140f2e2394b07190e606a0a826ba` | §1.16 `step_relax` asserts its own result |
| 2026-08-02 | `config.sh` | `93c39e456c516e65a3a2354e9beaec3f` | §1.16 `REQUIRE_RELAX_CONVERGED` |

`lib/generate.sh` and `lib/init.sh` are unchanged since 2026-07-29.

**`qe.sh`, `config.sh` and every `lib/` file must be byte-identical on the
cluster, the laptop and GitHub** — only `MAINTENANCE.md` differs, and only in
§5, which is generalised in the published copy because the repo is public.
They autodetect the machine rather than being configured for it, so there is
never a reason for them to diverge. Compare with
`md5sum qe.sh config.sh lib/*.sh` on each side; a difference is a bug, not a
setting.

Check the running copy with `md5sum qe.sh`. If it matches no row, someone
edited it without adding an entry here — add one.
