# SETUP — what an input needs before the workflow will take it

Checklist for getting one material through `relax -> scf -> band -> DOS`.
`README.md` explains what the workflow does; `MAINTENANCE.md` is for whoever
edits `qe.sh`. This file is the one to read before your first run.

Everything here is enforced by the script and fails with a message naming the
cause — except the two items marked **not checkable**, which are on you.

---

## 1. Files and names

Two files, in a folder of their own:

    cases/ws2/
      ws2_relax.in      your input
      ws2_band.path     the high-symmetry path for this lattice

Rules:

- The input must end in **`_relax.in`** — underscore, not `ws2.relax.in`.
  The script keys on that suffix to tell a case from a step name, so
  `qe.sh scf a_relax.in` is unambiguous. A `.relax.in` file is rejected.
- The **case name** is everything before `_relax.in` (`ws2` above). The path
  file must be `<case>_band.path` — the same word, or it is not found.
- **One case per folder.** Results are named from `prefix` (default `pwscf`),
  so two cases in one folder overwrite each other's `pwscf.dos`,
  `pwscf.bands.dat` and `work/`. This is what forced the full SCF+NSCF+BANDS
  redo of all four gases in the MoS2 project.

Every generated file lands next to the input: `ws2_scf.in`, `ws2_scf.out`,
`ws2_band.in`, ..., plus `cache/` and `work/`.

---

## 2. Hard requirements in the input

| Requirement | Why | If wrong |
|---|---|---|
| `calculation = 'relax'` or `'vc-relax'` | the pipeline starts by relaxing, then reads the relaxed geometry out of the output | an `scf` output has no `ATOMIC_POSITIONS` to extract; fails at step 3 |
| `ibrav = 0` | steps hand geometry over as an explicit `CELL_PARAMETERS` card, which only exists for `ibrav = 0` | rejected at step 1, naming the value found |
| an explicit `CELL_PARAMETERS` card | same | rejected at extract |
| `K_POINTS automatic` + a `nk1 nk2 nk3` line, **or** `K_POINTS gamma` | the nscf step densifies a mesh; an explicit k-list has no mesh to scale | rejected at step 1 |
| `pseudo_dir` pointing at a real folder | | pw.x aborts with `file ... not found` |
| every `.upf` in `ATOMIC_SPECIES` present there | | same |
| `nat`, `ntyp`, `ecutwfc` | | rejected at step 1 |

Check the pseudopotentials before submitting — a wrong `pseudo_dir` is what
made every NO2 stage abort in the MoS2 project (it pointed at another
person's account):

    ls $(grep pseudo_dir ws2_relax.in | cut -d"'" -f2)

### Formatting

- Leave a **blank line after the `ATOMIC_SPECIES` block**, or start the next
  card on its own line. Both work now; the parser stops at a blank line or at
  any card header.
- `gamma` cases need `NPOOL_WANTED=1` in `config.sh`: one k-point cannot be
  split across pools. The script says so rather than letting pools idle.

---

## 3. What you do NOT have to repeat

Anything else the input declares is carried into every generated
scf/band/nscf input automatically. You write it once, in the relax input.

Carried through:

- all remaining `&CONTROL`, `&SYSTEM`, `&ELECTRONS` keys — `nbnd`, `nspin`,
  `starting_magnetization(i)`, `vdw_corr`, `ecutrho`, `tot_charge`,
  `input_dft`, `assume_isolated`, `tefield`/`dipfield`, `edir`/`emaxpos`/
  `eopreg`/`eamp`, `mixing_mode`, `electron_maxstep`, ...
- the `HUBBARD` card (DFT+U, QE 7.x) and the `OCCUPATIONS` card

Deliberately dropped, because they mean nothing outside a relax:
`restart_mode`, `nstep`, `etot_conv_thr`, `forc_conv_thr`, the `&IONS` and
`&CELL` namelists, and the `CONSTRAINTS` / `ATOMIC_VELOCITIES` /
`ATOMIC_FORCES` cards. Also dropped: `celldm`, `A`, `B`, `C`, `cosAB`,
`cosAC`, `cosBC` — the lattice comes from the extracted `CELL_PARAMETERS`, and
a second definition of the same cell is only a way for the two to disagree.

`cell_dofree = '2Dxy'` in `&CELL` is read separately: it tells the nscf step
to keep k_z = 1 instead of scaling it. Set it for a slab; leave it out for
bulk.

Filled in only if you omit them: `occupations` (defaults to `fixed`),
`conv_thr`, `mixing_beta`, and — only when `occupations = 'smearing'` —
`smearing` and `degauss`. The parser prints a `note:` line whenever it uses a
default, so read those.

---

## 4. The band path

The one file you must write yourself. Format, with `__BAND_POINTS__` replaced
automatically by `BAND_POINTS` from `config.sh`:

    K_POINTS crystal_b
    4
    0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
    0.5000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! M
    0.3333333333  0.3333333333  0.0000000000  __BAND_POINTS__   ! K
    0.0000000000  0.0000000000  0.0000000000   1                ! G

That example is Γ–M–K–Γ, correct for a **hexagonal** cell — graphene, MoS2,
WS2. Copy it:

    cp template/band.path.hexagonal_example cases/ws2/ws2_band.path

**Not checkable (1):** nothing verifies the path suits your lattice. Give a
cubic material the hexagonal path and you get a band structure along a
meaningless path, with no error anywhere. The file is required precisely so
this is a decision you make, rather than a default you inherit — but the
decision is still yours.

---

## 5. Material types this has been checked against

| | |
|---|---|
| 2D slab, hexagonal (graphene, MoS2, WS2) | yes |
| 3D bulk, any Bravais lattice | yes |
| insulator / semiconductor (`occupations='fixed'`) | yes |
| metal with smearing | yes |
| spin-polarised (`nspin=2`) | yes |
| dispersion-corrected (`vdw_corr`) | yes |
| DFT+U (`HUBBARD` card, or `lda_plus_u` on QE 6.x) | yes |
| 3+ atomic species | yes |
| isolated molecule (`K_POINTS gamma`, `NPOOL=1`) | yes |
| `ibrav /= 0` | **no** — rejected, see §2 |
| explicit k-list (`K_POINTS crystal`/`tpiba`) | **no** — rejected, see §2 |

**Not checkable (2):** none of this says your *physics* is converged. Vacuum
thickness, cutoff and k-mesh are yours to converge. The test MoS2 cell in
`cases/` has only ~6 Å of vacuum and shows a visibly too-small gap because of
it — it exercises the pipeline, it is not a result.

---

## 6. Dry-run before you submit

Free, no MPI, a few seconds, and it catches everything in §2:

    bash qe.sh dump cases/ws2/ws2_relax.in

Read three things in the output:

1. `NAT`, `NTYP`, `ECUTWFC`, `K_POINTS` — what you meant?
2. `passthrough &SYSTEM:` — is `vdw_corr` there, if you set it? If a setting
   you care about is missing from these lines, it will not reach the scf.
3. any `note: ... using default ...` — a parameter you did not write is being
   filled in. Agree with it, or write it explicitly.

Then run:

    sbatch qe.sh cases/ws2/ws2_relax.in           # cluster
    sbatch -p interactive qe.sh cases/...         # when short is full
    bash   qe.sh cases/ws2/ws2_relax.in           # laptop, no Slurm

If a run is interrupted (time limit, `scancel`), clear its scratch before
re-running — `work/` is not reset automatically yet:

    rm -rf cases/ws2/{work,cache,logs}

---

## 7. Results

In the case folder:

| File | What |
|---|---|
| `pwscf.bands.dat.gnu` | band structure data, ready to plot |
| `pwscf.dos` | DOS; the first line carries E_Fermi |
| `ws2_nscf.out` | grep `the Fermi energy is` |
| `cache/structure.in` | the geometry actually used |

The log ends with `Workflow Finished Successfully`. A failed step stops there
and prints a diagnosis plus the last 40 lines of QE's output.

When plotting, shift energies relative to E_Fermi — but **do not compare
absolute E_Fermi between machines or QE versions.** For a gapped system that
value is under-determined and each version lands somewhere different (3.126 eV
vs 2.143 eV for the same MoS2, with identical eigenvalues). Align on a band
edge instead.
