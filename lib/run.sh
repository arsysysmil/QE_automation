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

step_bandsx() {
    require_cache
    load_modules

    local bands_in="$INPUT_DIR/${CASE_NAME}_bandsx.in"
    local bands_out="$INPUT_DIR/${CASE_NAME}_bandsx.out"

    cat > "$bands_in" <<EOF
&BANDS
    prefix = '$PREFIX'
    outdir = '$OUTDIR'
    filband = '${PREFIX}.bands.dat'
/
EOF

    echo "Running bands.x"
    (
        cd "$INPUT_DIR"
        $MPI $BANDS $POOL_FLAG < "$(basename "$bands_in")" > "$(basename "$bands_out")"
    )

    check_done "$bands_out" "bands.x"
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
# for these four.
step_relax() { require_cache; run_pw "$RELAX_IN"; }
step_scf()   { require_cache; run_pw "$SCF_IN";   }
step_band()  { require_cache; run_pw "$BAND_IN";  }
step_nscf()  { require_cache; run_pw "$NSCF_IN";  }
