#!/bin/bash
# Steps that launch MPI: pw.x, bands.x, dos.x.
#
# Sourced by qe.sh. Not executable on its own.

run_pw() {
    local infile="$1"
    local outfile="${infile%.in}.out"

    load_modules

    echo "Running pw.x : $(basename "$infile") -> $(basename "$outfile")"
    (
        cd "$INPUT_DIR"
        $MPI $PW $POOL_FLAG < "$(basename "$infile")" > "$(basename "$outfile")"
    )

    check_done "$outfile" "pw.x ($(basename "$infile"))"
}

# One bands.x run: one spin channel, one filband.
run_bandsx_once() {
    local tag="$1"        # "" for unpolarised, "up" / "dn" otherwise
    local component="$2"  # empty, or 1 / 2
    local filband="$3"

    local suffix="" label="bands.x"
    if [[ -n "$tag" ]]; then
        suffix="_$tag"
        label="bands.x (spin $tag)"
    fi

    local bands_in="$INPUT_DIR/${CASE_NAME}_bandsx${suffix}.in"
    local bands_out="$INPUT_DIR/${CASE_NAME}_bandsx${suffix}.out"

    {
        printf '&BANDS\n'
        printf "    prefix = '%s'\n" "$PREFIX"
        printf "    outdir = '%s'\n" "$OUTDIR"
        printf "    filband = '%s'\n" "$filband"
        [[ -n "$component" ]] && printf '    spin_component = %s\n' "$component"
        printf '/\n'
    } > "$bands_in"

    echo "Running $label -> $filband"
    (
        cd "$INPUT_DIR"
        $MPI $BANDS $POOL_FLAG < "$(basename "$bands_in")" > "$(basename "$bands_out")"
    )

    check_done "$bands_out" "$label"
}

# bands.x writes ONE spin channel per run, and `spin_component` defaults to 1.
#
# dos.x writes both channels without being asked, so for an nspin=2 case a
# single bands.x pass leaves the two halves of <case>_band_dos.png describing
# different things: spin up in the band panel, both spins in the DOS panel.
# Hence one pass per channel here.
#
# Unpolarised runs are untouched: same single pass, same <prefix>.bands.dat.
#
# noncolin is not the same thing. There the two channels are not separable and
# spin_component means nothing to bands.x, so it takes the single-pass path.
step_bandsx() {
    require_cache
    load_modules

    local noncolin="${NONCOLIN:-}"

    if [[ "${NSPIN:-}" == "2" && "${noncolin,,}" != *true* ]]; then
        echo "  nspin = 2: running bands.x once per spin channel"
        run_bandsx_once up 1 "${PREFIX}.bands.up.dat"
        run_bandsx_once dn 2 "${PREFIX}.bands.dn.dat"
        return 0
    fi

    if [[ "${noncolin,,}" == *true* ]]; then
        echo "  noncolin: spin channels are not separable, one pass"
    fi

    run_bandsx_once "" "" "${PREFIX}.bands.dat"
}

step_dos() {
    require_cache
    load_modules

    local dos_in="$INPUT_DIR/${CASE_NAME}_dos.in"
    local dos_out="$INPUT_DIR/${CASE_NAME}_dos.out"

    cat > "$dos_in" <<EOF
&DOS
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    fildos = '${PREFIX}.dos'
    DeltaE = $DOS_DELTAE
/
EOF

    echo "Running dos.x"
    (
        cd "$INPUT_DIR"
        $MPI $DOS < "$(basename "$dos_in")" > "$(basename "$dos_out")"
    )

    check_done "$dos_out" "dos.x"
}

# The four steps that are just "pw.x on one of the generated inputs". They
# exist as named functions so the step registry in qe.sh can dispatch every
# step the same way - name -> step_<name> - instead of carrying a special case
# for these four. None of them is only that any more: each checks something
# about the file it is handed before spending a node on it.

# The relax is the one step that can finish cleanly and still hand on a useless
# result: pw.x prints JOB DONE. whether or not the ionic minimisation
# converged. Checked here as well as in step_extract so a full pipeline stops
# at step 2 instead of after the scf has run.
step_relax() { require_cache; run_pw "$RELAX_IN"; assert_relax_converged "$RELAX_OUT"; }

# The other three check that the input they are about to run is not older than
# what it was generated from. The band step also watches <case>_band.path:
# editing the k-path and then running `band` without `gen-band` would walk the
# OLD path and produce a clean band structure of the wrong thing.
step_scf() {
    require_cache
    assert_generated_fresh "$SCF_IN" gen-scf "$INPUT_ABS" "$CACHE_FILE" "$STRUCTURE_FILE"
    run_pw "$SCF_IN"
}

step_band() {
    require_cache
    assert_generated_fresh "$BAND_IN" gen-band \
        "$INPUT_ABS" "$CACHE_FILE" "$STRUCTURE_FILE" "$BAND_PATH_FILE"
    run_pw "$BAND_IN"
}

step_nscf() {
    require_cache
    assert_generated_fresh "$NSCF_IN" gen-nscf "$INPUT_ABS" "$CACHE_FILE" "$STRUCTURE_FILE"
    run_pw "$NSCF_IN"
}
