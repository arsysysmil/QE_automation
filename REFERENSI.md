# REFERENSI

Rujukan teknis QE_automation. Cara pemakaian ada di [`README.md`](README.md);
file ini menjelaskan cara kerja bagian dalamnya, apa yang ditolak sistem
beserta alasannya, dan batasan yang diketahui.

---

# 1. Aliran data antar tahap

Semua dioper lewat file di sebelah input, jadi tiap tahap bisa dijalankan
sendiri asal tahap sebelumnya sudah menghasilkan yang dibacanya.

```
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
```

Pertemuan di tengah itulah penyalinan yang ingin dihapus sistem ini: geometri
hasil relaksasi dibaca satu kali, dipakai ketiga input hasil generate.

## File per case

```
<case>_relax.in                    input kamu
<case>_band.path                   WAJIB untuk tahap band
<case>_initial.cif                 struktur sebelum relaksasi
<case>_relaxed.cif                 struktur sesudah relaksasi
cache/<case>.parser.cache          nilai hasil parsing input
cache/<case>.structure.in          geometri hasil relaksasi
logs/<case>.status.tsv             tahap mana yang jalan, dan bagaimana selesainya
<prefix>.bands.dat.gnu             data band            (bands.x)
<prefix>.bands.{up,dn}.dat.gnu     data band per kanal spin, nspin=2
<prefix>.dos                       data DOS             (dos.x)
<case>_band.png                    gambar               (plot)
<case>_dos.png
<case>_band_dos.png
<case>_plot.py  atau  _plot.gnu    skrip penggambarnya - milikmu, bebas diedit
```

---

# 2. Jenis material yang diterima

| Input | Jalan | Keterangan |
|---|---|---|
| Slab 2D heksagonal (graphene, MoS₂, WS₂) | ya | `cell_dofree='2Dxy'` menjaga k_z tetap 1 |
| Bulk 3D, kisi Bravais apa pun, `ibrav = 0` | ya | nscf memperbesar ketiga arah |
| Insulator / semikonduktor, `occupations='fixed'` | ya | smearing/degauss tidak ikut ditulis |
| Logam dengan smearing | ya | |
| Terpolarisasi spin (`nspin=2`) | ya | bands.x jalan dua kali |
| Terkoreksi dispersi (`vdw_corr`) | ya | lewat passthrough |
| DFT+U, card `HUBBARD` (QE 7.x) | ya | lewat passthrough card |
| DFT+U, `lda_plus_u` di `&SYSTEM` (QE 6.x) | ya | lewat passthrough namelist |
| Banyak spesies (`ntyp` ≥ 3) | ya | |
| Molekul terisolasi, `K_POINTS gamma` | ya, `NPOOL_WANTED=1` | |
| **`ibrav ≠ 0`** (celldm / A,B,C) | **tidak** | tidak ada card `CELL_PARAMETERS` untuk dioper; gagal di `extract` |
| **Daftar k eksplisit** (`crystal`/`tpiba`) | **tidak** | tidak ada mesh untuk diperbesar nscf; ditolak di tahap 1 |

Kedua baris "tidak" gagal disertai pesan yang menyebut penyebab dan solusinya.

Catatan versi: **QE 6.7 belum punya card `HUBBARD`** (baru ada di 7.1). Di versi
itu DFT+U ditulis `lda_plus_u` + `Hubbard_U(i)` di `&SYSTEM`, yang sudah terbawa
lewat passthrough namelist.

---

# 3. Apa yang ditolak sistem, dan kenapa

Tiap butir di bawah ini adalah kegagalan yang tanpa pemeriksaan akan selesai
dengan exit 0 dan fisika yang berbeda. Menolak itulah inti alat ini;
mengotomatiskan pengetikan hanya efek samping.

## Relaksasi yang tidak konvergen

pw.x mencetak `JOB DONE.` baik minimisasi ionik konvergen maupun tidak — BFGS
yang kehabisan `nstep` selesai dengan rapi dan meninggalkan langkah terakhirnya
di output. Tahap `relax` dan `extract` mewajibkan baris
`bfgs converged in N scf cycles`. Diperiksa di `extract` juga, supaya run
relaksasi dari luar sistem ini yang disalin masuk ikut tercakup.
`REQUIRE_RELAX_CONVERGED=0` di `config.sh` menurunkannya jadi peringatan.

Komponen gaya terbesar dibandingkan dengan `forc_conv_thr` milik run itu
sendiri, dan dilaporkan kalau melebihi. Untuk `vc-relax`, angka itu berasal
dari scf final yang QE jalankan pada sel hasil relaksasi dengan vektor-G
dihitung ulang. Kalau di situ melebihi ambang, berarti strukturnya konvergen
pada basis awalnya, bukan pada basis yang benar — **tekanan Pulay**. Obatnya:
jalankan `vc-relax` lagi dari struktur akhir sampai selnya berhenti bergerak,
atau naikkan `ecutwfc` sampai keduanya sepakat.

Tanda tangan Pulay yang mudah dilihat: jarak besar antara energi BFGS terakhir
dan baris "Final scf calculation at the relaxed structure".

## Jalur band yang bukan milik kisinya

`<case>_band.path` wajib, tidak pernah didefault. `qe.sh init` mengukur selnya,
mengklasifikasikan kisinya, mencetak klasifikasinya, lalu menulis jalur yang
cocok — dan menolak menebak kalau selnya tidak terklasifikasi. Jalur heksagonal
pada sel kubik menghasilkan struktur pita yang bersih dari hal yang salah.

Kasus heksagonal punya dua setting: kisi yang sama, basis resiprok yang
berbeda.

| Setting | a₂ | K |
|---|---|---|
| γ = 60° | `(a/2, a√3/2, 0)` | **(2/3, 1/3, 0)** |
| γ = 120° | `(−a/2, a√3/2, 0)` | **(1/3, 1/3, 0)** |

`template/` berisi satu contoh untuk masing-masing.

## Parameter yang hilang diam-diam saat men-generate input

`&CONTROL`, `&SYSTEM`, dan `&ELECTRONS` disalin sebagai baris mentah dikurangi
key yang ditulis generator sendiri, jadi `nbnd`, `nspin`,
`starting_magnetization(1)`, `vdw_corr`, card `HUBBARD`, dan apa pun yang lain
ikut selamat. Disalin mentah, bukan diparsing, supaya key berindeks lolos utuh.
Parser mencetak apa saja yang dibawanya.

`CONSTRAINTS`, `ATOMIC_VELOCITIES`, dan `ATOMIC_FORCES` sengaja **tidak**
dibawa — ketiganya hanya bermakna untuk relaksasi atau MD.

## Satu kanal spin mewakili dua

bands.x menulis satu kanal per run dan defaultnya kanal pertama, sedangkan
dos.x menulis keduanya tanpa diminta. Untuk kasus `nspin=2` itu berarti panel
band menampilkan spin up saja di sebelah panel DOS dua kanal. Tahap `bandsx`
karena itu jalan sekali per kanal, dan kedua gambar menggambar keduanya: up
garis penuh, down garis putus. `noncolin` bukan hal yang sama — di sana kedua
kanal tidak terpisahkan, jadi tetap satu pass.

## File turunan lebih tua dari sumbernya

Cache, geometri, dan input hasil generate semuanya snapshot. Edit input maka
cache dibaca ulang; ulangi relaksasi maka geometri diambil ulang; edit
`<case>_band.path` lalu jalankan `band` tanpa `gen-band` maka tahap itu
berhenti, bukan menyusuri jalur lama. Yang paling akhir ditulis, itu yang
menang — termasuk kalau kamu sendiri yang mengedit input hasil generate, karena
editanmu jadi yang termuda.

Memakai mtime, bukan checksum: tidak butuh state tambahan, dan "harus lebih
baru" berarti file yang ditulis pada detik yang sama tidak ikut memicunya.

## Pseudopotensial hilang, sebelum antre bukan sesudah

`pseudo_dir` dan tiap `.upf` di `ATOMIC_SPECIES` diverifikasi untuk semua case
sebelum case pertama mulai. pw.x baru menemukannya beberapa detik setelah job
yang antre berjam-jam akhirnya jalan. Fatal hanya untuk tahap yang meluncurkan
pw.x — menyiapkan input di laptop terhadap `pseudo_dir` milik cluster hanya
mencetak catatan lalu lanjut.

## Dua case dalam satu folder menulis file yang sama

bands.x dan dos.x menamai keluarannya dari `prefix`, jadi `prefix` yang kembar
berarti satu `<prefix>.dos` milik case yang selesai terakhir. `prefix` yang
kosong didefault ke nama case; `prefix` yang eksplisit dan kembar ditolak
sebelum apa pun jalan.

## Grafik band tanpa pita di atas tingkat Fermi

Lihat bagian `nbnd` di `README.md`. Ringkasnya: `gen-band` dan `gen-nscf`
menghitung `nbnd` sendiri kalau input tidak menyebutnya, sumber jumlah
elektronnya `<case>_scf.out` atau `z_valence` dari pseudopotensial, dan tahap
`scf` sengaja tidak diberi.

---

# 4. Kalau run terputus

Tiap tahap dicatat ke `logs/<case>.status.tsv` **sebelum** dimulai, jadi tahap
yang tidak punya baris hasil sesudahnya adalah tahap yang terputus — berlaku
bahkan di bawah SIGKILL, yang dipakai batas waktu maupun OOM killer dan tidak
bisa ditangkap trap mana pun. `qe.sh check` mengubahnya jadi kalimat:

```
Last run of 'gra3' (job 412899, started 2026-08-02 01:52:03):
   1/13  parser    OK       0h0m3s
   2/13  relax     RUNNING  started 2026-08-02 01:52:06

INTERRUPTED: step 2/13 (relax) started at 2026-08-02 01:52:06 and never
  finished. The process was killed while it was running - walltime,
  scancel, out of memory, or a node failure - so nothing after it ran.
  What killed it:
    sacct -j 412899 --format=JobID,State,ExitCode,Elapsed,Timelimit,MaxRSS
```

Mencatat dengan menambah, bukan menimpa — menjalankan ulang `plot` untuk
memperbaiki gambar tidak boleh menghapus catatan run 13 tahap yang menghasilkan
datanya.

---

# 5. Pengaturan di `config.sh`

| Pengaturan | Bawaan | Keterangan |
|---|---|---|
| `NPOOL_WANTED` | 4 | jumlah pool k-point yang diminta |
| `NSCF_KPOINT_SCALE` | 2 | mesh nscf = mesh scf × ini |
| `DOS_DELTAE` | 0.01 | lebar bin DOS |
| `AUTO_NBND_FACTOR` | 1.5 | pengali `nbnd` untuk band/nscf; 0 mematikan |
| `DEFAULT_OCCUPATIONS` | fixed | dipakai hanya kalau input tidak menyebut |
| `DEFAULT_CONV_THR` | 1.0d-8 | idem |
| `DEFAULT_MIXING_BETA` | 0.7 | idem |
| `DEFAULT_SMEARING` / `DEFAULT_DEGAUSS` | mv / 0.02 | idem, hanya untuk `occupations='smearing'` |
| `REQUIRE_RELAX_CONVERGED` | 1 | 0 menurunkannya jadi peringatan |
| `PLOT_ENGINE` | auto | matplotlib, gnuplot, none |
| `PLOT_EMIN` / `PLOT_EMAX` | −5.0 / 5.0 | jendela energi gambar baru |
| `CASES_PARALLEL` | 1 | > 1 menumpuk case; lihat catatan di bawah |
| `QE_MODULES` | — | daftar module, kosong di mesin tanpa `module` |

Semua fallback berawalan `DEFAULT_`. Awalan itu wajib: `config.sh` di-source
sesudah cache hasil parsing, jadi nama yang bertabrakan akan menggantikan apa
pun yang tertulis di file input.

`CASES_PARALLEL > 1` tersedia tapi tidak dianjurkan di sini — terukur 45–51
menit melawan 3m07s sekuensial untuk pekerjaan yang sama. Penyebabnya belum
ditemukan; jangan ubah bawaannya tanpa mengukur ulang.

## Pool k-point (`NPOOL`)

`NPOOL` mengoper `-nk` ke `pw.x` dan `bands.x`. Pool membagi rank jadi
kelompok-kelompok yang masing-masing mengambil sebagian titik k, sehingga jatah
gelombang bidang tiap kelompok tetap besar.

Tanpa itu, sel kecil di atas banyak rank membuat sebagian rank kebagian nol
vektor-G, dan `bands.x` gagal dengan:

```
Error in routine diropn (3): wrong record length
```

Panjang rekaman fungsi gelombang adalah `nbnd × npwx`, dan `npwx` dihitung per
rank. QE sebenarnya sudah memberi tahu lebih dulu, di baris yang biasanya
terlewat:

```
Message from routine sym_rho_init:
some processors have no G-vectors for symmetrization
```

Syarat: `NPROC` harus habis dibagi `NPOOL`, dan `NPOOL` tidak boleh melebihi
jumlah titik k. Keduanya diperiksa sebelum apa pun diluncurkan. `bands.x`
sengaja diberi flag yang sama — pasca-pemrosesan harus memakai layout pool dari
run yang menghasilkan fungsi gelombangnya. `dos.x` tidak diberi.

`NPROC` diambil dari `SLURM_NTASKS` di bawah Slurm, kalau tidak ada dari
**jumlah core fisik** — bukan `nproc`, yang menghitung hyperthread dan membuat
Open MPI menolak start dengan `not enough slots available in the system`.

---

# 6. Mengubah kodenya

Menambah tahap butuh dua suntingan: tulis `step_<nama>()` di file `lib/` yang
sesuai, lalu tambahkan `<nama>` ke `PIPELINE_STEPS` di `qe.sh` pada posisi
jalannya. Penomoran tahap (`4/13`) dihitung dari daftar itu, jadi tidak ada
yang perlu dinomori ulang.

```
qe.sh              orkestrator: path, config, daftar tahap, dispatch
lib/common.sh      lingkungan, path per case, kesegaran file, status, diagnosa
lib/parser.sh      membaca input relaksasi, preflight pseudopotensial
lib/structure.sh   geometri hasil relaksasi + pemeriksaan konvergensi
lib/cif.sh         struktur sebagai CIF, sebelum dan sesudah
lib/generate.sh    menulis input scf / band / nscf
lib/run.sh         tahap yang meluncurkan pw.x / bands.x / dos.x
lib/init.sh        deteksi kisi + jalur band
lib/plot.sh        gambar band / DOS dari data yang sudah jadi
```

File `lib/` di-**source** ke satu proses, jadi ada satu lingkungan dan satu
`config.sh`. Jangan meluncurkannya lewat `bash -c`: login shell akan
men-source ulang `/etc/profile` dan bisa menukar `mpirun` dengan yang tidak
bisa meluncurkan `pw.x` tertaut Intel-MPI.

## Menguji tanpa menghabiskan jatah antrean

Semua tahap kecuali empat yang meluncurkan MPI berjalan di login node dalam
hitungan detik:

```bash
bash qe.sh parser   <case>_relax.in
bash qe.sh dump     <case>_relax.in
bash qe.sh extract  <case>_relax.in     # butuh <case>_relax.out yang sudah ada
bash qe.sh gen-scf  <case>_relax.in
bash qe.sh gen-band <case>_relax.in
bash qe.sh gen-nscf <case>_relax.in
```

File `<case>_relax.out` tulisan tangan yang isinya hanya blok
`Begin final coordinates` sudah cukup untuk menguji `extract` dan ketiga
generator. Buat sel akhirnya berbeda dari sel input, supaya kedua sumbernya
bisa dibedakan pada geometri hasil ekstraksi.

Belum ada tes otomatis.

Kalau partisi `short` penuh, `sbatch -p interactive` mulai seketika — tapi
node-nya dipakai bersama, jadi ukur `-t` untuk kondisi ramai, bukan kondisi
sepi.

---

# 7. Batasan yang diketahui

1. **`ibrav ≠ 0` tidak dikonversi.** Ini penghalang terbesar bagi orang lain
   yang ingin memakainya: hampir semua input dari tutorial, paper, atau
   Materials Project memakai `celldm`, jadi memakai sistem ini dimulai dengan
   konversi tangan. `ibrav` 1–14 adalah rumus tertutup, jadi ini bisa
   diotomatiskan.
2. **Tidak ada tes otomatis.**
3. **Job yang terputus tidak bisa dilanjutkan**, hanya diulang.
4. **`bandsx` tidak boleh diulang setelah `nscf`** — keempat tahap pw.x berbagi
   satu `outdir` dan `prefix`. Sudah tertulis di dokumen, belum dideteksi.
5. **Tidak ada reset `work/` sebelum sebuah tahap.** Job yang mati separuh
   jalan meninggalkan `work/` setengah tertulis yang dipakai ulang run
   berikutnya. Bersihkan manual.
6. **Uji 2D memakai `c/a > 2.0`.** Benar untuk monolayer, salah untuk kristal
   3D yang memang berlapis: grafit (c/a = 2,7) dan bulk 2H-MoS₂ (c/a = 3,9)
   sama-sama akan kehilangan dispersi Γ–A. Uji yang lebih jujur adalah sebaran
   koordinat z atom terhadap c, bukan rasio sumbu.
7. **PDOS dan work function belum ada.**
8. **`convergence NOT achieved` di scf tidak punya diagnosa** — keluar output
   pw.x mentah, bukan petunjuk soal `mixing_beta`, `conv_thr`, atau
   `diagonalization`.
9. **Sapuan `runlogs/` balapan dengan job serentak.** Kosmetik.
