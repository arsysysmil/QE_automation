# ARCHITECTURE

Rancangan internal QE_automation: bagaimana kodenya disusun, bagaimana state
berpindah antar tahap, dan aturan apa yang dijaga. Cara pemakaian ada di
[`README.md`](README.md) dan tidak diulang di sini.

---

# 1. Gambaran umum

Satu proses bash. `qe.sh` adalah orkestrator; `lib/` berisi implementasi tiap
urusan; `config.sh` berisi setting. Ketiganya di-**source** menjadi satu
proses, bukan dijalankan sebagai sub-proses terpisah.

```
                  ┌─────────────┐
                  │  config.sh  │   setting
                  └──────┬──────┘
                         │ source
                  ┌──────▼──────┐
   argumen ──────▶│    qe.sh    │   resolusi path, daftar tahap, dispatch
                  └──────┬──────┘
                         │ source
       ┌────────┬────────┼────────┬────────┬────────┐
       ▼        ▼        ▼        ▼        ▼        ▼
   common   parser  structure generate   run     init/plot/cif
```

Satu proses berarti satu lingkungan dan satu `config.sh`. Konsekuensinya:

- Tahap adalah fungsi shell biasa, sehingga mewarisi lingkungan module secara
  langsung. Tahap **tidak boleh** diluncurkan lewat `bash -c`: login shell akan
  men-source ulang `/etc/profile` dan dapat menukar `mpirun` dengan versi yang
  tidak bisa meluncurkan `pw.x` tertaut Intel-MPI.
- Fungsi bersama seperti `emit_pw_input()` ada satu kali, bukan disalin ke tiap
  generator.
- Urutan source menentukan presedensi nilai. Lihat §5.

## Deteksi lingkungan, bukan konfigurasi per mesin

`qe.sh`, `config.sh`, dan seluruh `lib/` dirancang agar **identik byte per
byte** di semua mesin. Perbedaan lingkungan diselesaikan saat runtime:

| Yang berbeda | Cara ditentukan |
|---|---|
| Jumlah proses | `SLURM_NTASKS` bila ada, selain itu jumlah core fisik |
| Lokasi `pw.x` | module bila `module` ada, selain itu `PATH` |
| Daftar module | `QE_MODULES` di `config.sh`, kosong bila tidak ada `module` |
| Direktori kerja | lokasi skrip, dengan `SLURM_SUBMIT_DIR` sebagai cadangan |

`module` dideteksi sebagai **fungsi** maupun biner: pada Lmod ia fungsi shell,
sehingga `command -v` saja tidak cukup.

Jumlah core diambil dari core fisik, bukan `nproc`. `nproc` menghitung
hyperthread, dan Open MPI mengalokasikan satu slot per core, sehingga `pw.x`
menolak start dengan `not enough slots available in the system`.

Di bawah `sbatch`, skrip dieksekusi dari salinan spool yang direktorinya tidak
berisi `config.sh` maupun `template/`. `resolve_root_dir()` karena itu menguji
tiap kandidat dengan memastikan `config.sh` benar-benar ada di sana, bukan
mengasumsikannya.

---

# 2. Peta kode

| File | Baris | Tanggung jawab |
|---|---|---|
| `qe.sh` | 970 | resolusi path, daftar tahap, validasi argumen, preflight, dispatch, trap, ringkasan |
| `config.sh` | 265 | setting, tanpa logika |
| `lib/common.sh` | 488 | lingkungan, path per case, aturan kesegaran file, file status, diagnosa, `check` |
| `lib/parser.sh` | 499 | membaca input relaksasi ke cache, preflight pseudopotensial |
| `lib/structure.sh` | 342 | geometri hasil relaksasi + pemeriksaan konvergensi |
| `lib/generate.sh` | 326 | menulis input scf/band/nscf, perhitungan `nbnd` |
| `lib/run.sh` | 143 | tahap yang meluncurkan pw.x, bands.x, dos.x |
| `lib/init.sh` | 283 | klasifikasi kisi + jalur band |
| `lib/plot.sh` | 697 | gambar band/DOS dari data yang sudah jadi |
| `lib/cif.sh` | 268 | struktur sebagai CIF, sebelum dan sesudah |

Pembagiannya per urusan, bukan per tahap: `lib/run.sh` memegang enam tahap
karena keenamnya sama-sama "luncurkan MPI lalu periksa hasilnya", sedangkan
`lib/plot.sh` memegang satu tahap yang isinya paling banyak.

---

# 3. Daftar tahap dan dispatch

Urutan pipeline tersimpan dalam **satu** array di `qe.sh`:

```bash
PIPELINE_STEPS=( parser relax extract cif gen-scf scf
                 gen-band band bandsx gen-nscf nscf dos plot )

EXTRA_STEPS=( all dump check init )     # dipanggil per nama, bukan bagian 'all'
MPI_STEPS=( relax scf band bandsx nscf dos )
```

Dispatch memetakan nama ke fungsi: `gen-scf` → `step_gen_scf`, tanda hubung
menjadi garis bawah. `qe.sh` memeriksa saat start bahwa tiap nama terdaftar
punya fungsi di baliknya.

Semua yang bergantung pada urutan diturunkan dari array ini:

- penomoran tahap yang dicetak (`4/13`)
- jumlah tahap di file status
- rentang `--from` / `--until`
- daftar tahap pada `usage()`

Karena itu menambah tahap tidak pernah berarti menomori ulang apa pun, dan
tidak ada daftar kedua yang harus dijaga tetap sinkron.

## Menjalankan sebagian pipeline

`--from` dan `--until` diimplementasikan sebagai **pemotongan array**:

```
--scf / --until=scf      potong sesudah 'scf'
--from=gen-band          potong sebelum 'gen-band'
```

Tidak ada penghitung terpisah yang perlu disesuaikan, karena semuanya sudah
diturunkan dari panjang array. Bagian yang dipotong disimpan di
`PIPELINE_SKIPPED_BEFORE` / `PIPELINE_SKIPPED_AFTER` untuk dua keperluan:

- **Preflight pseudopotensial ikut menyempit.** `step_needs_pseudo all`
  memeriksa array yang sudah dipotong, sehingga rentang yang berhenti sebelum
  pw.x pertama tidak tertahan oleh `pseudo_dir` yang hanya ada di HPC.
- **Run yang dipersempit tidak pernah mencetak `Workflow Finished
  Successfully`.** Baris itu akan terbaca seolah gambar sudah jadi. Yang
  dicetak adalah tahap terakhir yang dijalankan, tahap yang dilewati, dan
  perintah `--from` untuk melanjutkan.

## Menambah tahap

Dua suntingan:

1. tulis `step_<nama>()` di file `lib/` yang sesuai
2. tambahkan `<nama>` ke `PIPELINE_STEPS` pada posisi jalannya

Bila tahap itu meluncurkan MPI, tambahkan juga ke `MPI_STEPS` agar preflight
pseudopotensial mengenalinya.

Semua tahap kecuali enam yang meluncurkan MPI berjalan di login node dalam
hitungan detik, sehingga perubahan dapat diuji tanpa submit:

```bash
bash qe.sh parser   <case>_relax.in
bash qe.sh extract  <case>_relax.in     # butuh <case>_relax.out
bash qe.sh gen-scf  <case>_relax.in
```

File `<case>_relax.out` tulisan tangan yang isinya hanya blok
`Begin final coordinates` sudah cukup untuk menguji `extract` dan ketiga
generator. Sel akhirnya dibuat berbeda dari sel input agar kedua sumber dapat
dibedakan pada hasil ekstraksi.

---

# 4. State antar tahap

Tidak ada state dalam memori yang bertahan antar tahap. Semuanya dioper lewat
file di sebelah input, sehingga tiap tahap dapat dijalankan sendiri asal tahap
sebelumnya sudah menghasilkan yang dibacanya.

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

Pertemuan di tengah adalah alasan sistem ini ada: geometri hasil relaksasi
dibaca satu kali, lalu dipakai ketiga input hasil generate.

## Penamaan per case, bukan per folder

Setiap file turunan membawa nama case: `cache/<case>.parser.cache`,
`cache/<case>.structure.in`, `logs/<case>.status.tsv`. Tanpa itu, folder berisi
tiga case akan menulis satu pasang file yang sama dan case terakhir menang.
Pipeline penuh kebetulan selamat dari hal itu karena tiap case mem-parsing lalu
langsung mengonsumsi cache-nya sendiri, tetapi `qe.sh parser <folder>` yang
disusul `qe.sh gen-scf <folder>` akan meng-generate seluruh input dari
parameter case terakhir.

Alasan yang sama berlaku untuk `prefix`. `bands.x` dan `dos.x` menamai
keluarannya dari `prefix`, jadi `prefix` kosong yang didefault ke `pwscf` milik
QE membuat semua case menulis satu `pwscf.dos`. Sistem menurunkannya dari nama
case; `prefix` eksplisit yang kembar tidak bisa diperbaiki oleh default apa
pun, sehingga ditolak sebelum apa pun berjalan.

## Versi cache

`cache/<case>.parser.cache` membawa `CACHE_VERSION`, dibandingkan dengan
`CACHE_VERSION_EXPECTED` (kini `4`) di `lib/parser.sh`. Bila tidak cocok,
cache dibangun ulang, bukan di-source: field yang hilang akan membuat
passthrough kosong diam-diam, yang tidak dapat dibedakan dari passthrough yang
rusak.

**Naikkan `CACHE_VERSION_EXPECTED` setiap kali ada field baru di cache.**
Namanya sengaja berbeda dari `CACHE_VERSION` karena men-source cache akan
menimpa nilai pembandingnya.

## Aturan kesegaran

Cache, geometri, dan input hasil generate semuanya snapshot dari sesuatu yang
bisa berubah di bawahnya. Aturannya satu baris:

> File turunan tidak boleh lebih **tua** dari sumbernya.

Memakai mtime, bukan checksum: tidak butuh state tambahan, dan "harus lebih
baru" berarti file yang ditulis pada detik yang sama tidak ikut memicunya.

Cache di bawah `cache/` dibangun ulang otomatis karena bukan file tulisan
tangan siapa pun. Input hasil generate tidak: sistem berhenti dan meminta tahap
`gen-*` dijalankan, karena suntingan tangan pada file itu adalah hal yang sah
dan tidak boleh ditimpa diam-diam. Suntingan tangan otomatis menang, karena
menjadi file termuda.

## Catatan status

`logs/<case>.status.tsv` mencatat tiap tahap **sebelum** tahap itu dimulai.
Baris `RUNNING` tanpa hasil sesudahnya berarti tahap tersebut terputus — benar
bahkan di bawah SIGKILL, yang dipakai batas waktu maupun OOM killer dan tidak
dapat ditangkap trap mana pun.

Dua rincian yang perlu dipertahankan:

- **Menambah, bukan menimpa.** Menjalankan ulang `plot` untuk memperbaiki
  gambar tidak boleh menghapus catatan run 13 tahap yang menghasilkan datanya.
  Hanya blok setelah baris `# run` terakhir yang dilaporkan.
- **Trap dipasang di dalam subshell per case.** Bash mereset trap induk di
  dalam subshell, sehingga trap EXIT yang dipasang di luar tidak akan menyala
  untuk tahap yang benar-benar gagal.

Hasil tahap direkam dari trap EXIT, bukan setelah pemanggilan tahap, karena
sebagian besar fungsi tahap melaporkan kegagalan dengan `exit 1` sehingga kode
setelah pemanggilannya tidak pernah tercapai.

---

# 5. Lapisan setting

Presedensi, dari yang paling kuat:

```
file input  >  DEFAULT_* di config.sh  >  bawaan QE
```

`config.sh` di-source **sesudah** cache hasil parsing. Karena itu tidak boleh
ada nama di `config.sh` yang bertabrakan dengan yang ditulis cache — nama yang
sama akan menggantikan apa pun yang tertulis di file input, tanpa pesan.
Semua fallback berawalan `DEFAULT_` justru untuk itu.

Nama yang dipesan cache: `PREFIX`, `OUTDIR`, `PSEUDO_DIR`, `CALCULATION`,
`IBRAV`, `NAT`, `NTYP`, `ECUTWFC`, `ECUTRHO`, `OCCUPATIONS`, `SMEARING`,
`DEGAUSS`, `CONV_THR`, `MIXING_BETA`, `CELL_DOFREE`, `ATOMIC_SPECIES`,
`K_POINTS`.

## Passthrough

`get_param()` hanya mengenal 16 key. Sisanya harus tetap sampai ke input
scf/band/nscf, atau ketiganya akan mendeskripsikan fisika yang berbeda dari
relaksasinya tanpa error apa pun.

`&CONTROL`, `&SYSTEM`, dan `&ELECTRONS` karena itu disalin sebagai **baris
mentah** dikurangi key yang ditulis generator sendiri (`DROP_SYSTEM` di
`lib/parser.sh`). Mentah, bukan diparsing, supaya key berindeks seperti
`starting_magnetization(1)` dan bentuk yang belum pernah ditemui ikut lolos
utuh.

Card diperlakukan sama: `HUBBARD` dan `OCCUPATIONS` dibawa (`CARDS_KEPT`),
ditambahkan setelah `K_POINTS`. Urutan card bebas di QE, sehingga
`emit_extra_cards` dipanggil terakhir oleh tiap generator, bukan dilipat ke
dalam `emit_pw_input`. `CONSTRAINTS`, `ATOMIC_VELOCITIES`, dan `ATOMIC_FORCES`
sengaja tidak dibawa: ketiganya hanya bermakna untuk relaksasi atau MD.

## Pool k-point

`NPOOL` mengoper `-nk` ke `pw.x` dan `bands.x`. Pool membagi rank menjadi
kelompok yang masing-masing mengambil sebagian titik k, sehingga jatah
gelombang bidang tiap kelompok tetap besar.

Tanpa itu, sel kecil di atas banyak rank membuat sebagian rank kebagian nol
vektor-G, dan `bands.x` gagal dengan `Error in routine diropn (3): wrong record
length`. Panjang rekaman fungsi gelombang adalah `nbnd × npwx`, dan `npwx`
dihitung per rank. QE sudah memberi tahu lebih dulu lewat
`some processors have no G-vectors for symmetrization`.

`NPROC` harus habis dibagi `NPOOL`, dan `NPOOL` tidak boleh melebihi jumlah
titik k; keduanya diperiksa sebelum peluncuran. `NPOOL` juga dijepit ke pembagi
terbesar dari `NPROC` yang tidak melebihi `NPOOL_WANTED`, karena nilai tetap
akan gagal pada jumlah core yang tidak membaginya.

`bands.x` menerima flag yang sama dengan sengaja: pasca-pemrosesan harus
memakai layout pool dari run yang menghasilkan fungsi gelombangnya. `dos.x`
tidak menerimanya.

---

# 6. Keputusan desain

## Menolak, bukan menebak

Tiap pemeriksaan di sistem ini menangani kegagalan yang tanpa pemeriksaan akan
selesai dengan exit 0 dan fisika yang berbeda — bukan kegagalan yang membuat
program berhenti sendiri. Itu sebabnya penolakan adalah inti alat ini dan
otomatisasi pengetikan hanya efek sampingnya.

Konsekuensi rancangan: **validasi dilakukan sedini mungkin, bukan di tempat
nilainya dipakai.** Mode `K_POINTS` diperiksa di tahap 1, bukan di generator
nscf yang membutuhkannya, karena kalau tidak, bentuk yang tidak didukung baru
gagal setelah relax, scf, band, dan bands.x berjalan. Pseudopotensial diperiksa
untuk semua case sekaligus sebelum antre, karena pw.x baru menemukannya
beberapa detik setelah job yang antre berjam-jam akhirnya mulai.

## Sedini mungkin, tetapi tidak lebih fatal dari perlunya

Pemeriksaan pseudopotensial fatal hanya untuk tahap yang meluncurkan pw.x.
Menyiapkan input di mesin lokal terhadap `pseudo_dir` milik HPC adalah alur
kerja yang sah, jadi tahap lain hanya mencetak catatan lalu lanjut.

Pola yang sama pada tahap `plot`: ia **fail-soft**, mengembalikan sukses
walaupun tidak menggambar apa pun. Ia tahap terakhir dari pipeline yang mungkin
berjalan berjam-jam, dan node tanpa matplotlib bukan alasan menyatakan
perhitungan yang sudah selesai sebagai gagal. Kegagalannya dicetak penuh,
sehingga non-fatal, bukan senyap.

## Menghasilkan skrip, bukan menggambar langsung

Tahap `plot` menulis `<case>_plot.py` (atau `.gnu`) lalu menjalankannya. Gambar
untuk paper selalu perlu disetel, dan penyetelan itu tidak boleh menyentuh
`lib/`. Konsekuensi yang harus diterima: menjalankan ulang `qe.sh plot`
menimpa skrip tersebut.

Posisi tick diambil dari `bands.x`, label dari `<case>_band.in`. File `.path`
berisi koordinat fraksional, sedangkan sumbu x plot adalah jarak tempuh di
ruang resiprok, dan hanya `bands.x` yang sudah melakukan konversi itu. Label
diambil dari `.in` karena itulah yang benar-benar dilihat `bands.x`; menyunting
file `.path` setelah run akan memberi label pada data yang tidak
dideskripsikannya. Bila jumlahnya tidak cocok, tick **dinomori**, tidak
ditebak.

## Nol pada sumbu energi dari run nscf

E_Fermi tidak dibaca dari rapat muatan; ia dicari dengan mengintegralkan
okupasi atas mesh k, dan mesh scf lebih kasar daripada mesh nscf. Pada
semikonduktor, E_Fermi dari mesh scf yang kasar dapat jatuh di luar gap
sehingga garis nol menembus pita. Nilai nscf juga yang ditulis `dos.x` ke
header DOS, sehingga kedua panel memakai nol yang sama dengan data DOS.

Urutan sumber: output nscf → header DOS → output scf, dan jatuh ke scf
mencetak peringatan beserta alasannya.

## Simetri CIF ditulis `P 1`

Grup ruang yang ditebak dari koordinat hasil relaksasi menghasilkan CIF yang
salah tanpa pesan apa pun. Penampil seperti VESTA mendeteksi simetrinya sendiri
dengan toleransi yang dapat diatur pengguna.

## `nbnd` dihitung untuk band dan nscf, bukan scf

Bawaan QE meninggalkan grafik pita tanpa apa pun di atas tingkat Fermi. Itu
tidak salah untuk scf, yang tugasnya rapat muatan dan tidak memperoleh apa pun
dari pita kosong; keduanya salah untuk dua tahap yang justru ada untuk
menampilkan keadaan kosong.

Jumlah elektron diambil dari `<case>_scf.out` bila ada, selain itu dijumlahkan
dari `z_valence` di file `.UPF` — yang kedua diperlukan agar generator tetap
dapat dijalankan sendiri sebelum ada scf. Bila satu spesies saja tidak terbaca,
penjumlahan dibatalkan, karena jumlah yang kurang lebih buruk daripada tidak
ada jumlah sama sekali.

## Klasifikasi kisi diukur, tidak diwarisi

`qe.sh init` mengukur panjang rusuk dan sudut dari `CELL_PARAMETERS`, mencetak
klasifikasinya beserta angka di baliknya, lalu menolak menebak bila selnya
tidak terklasifikasi. Toleransinya 0,1% untuk panjang dan 0,5° untuk sudut:
1% terlalu longgar, karena distorsi yang justru menjadi inti fisika sebuah
material sering hanya sebesar ~1%.

Kasus heksagonal punya dua setting yang merupakan kisi sama tetapi basis
resiprok berbeda:

| Setting | a₂ | K |
|---|---|---|
| γ = 60° | `(a/2, a√3/2, 0)` | **(2/3, 1/3, 0)** |
| γ = 120° | `(−a/2, a√3/2, 0)` | **(1/3, 1/3, 0)** |

Sel jangkung (`c/a > 2`) diperlakukan sebagai slab dan jalurnya kehilangan
k_z, karena menyampel k_z dari celah vakum tidak bermakna.

---

# 7. Batasan arsitektural

Bukan daftar bug, melainkan hal yang mengikuti dari rancangan sekarang.

1. **`ibrav ≠ 0` tidak dikonversi.** Geometri dioper antar tahap sebagai card
   `CELL_PARAMETERS`, sehingga input yang mendeskripsikan kisinya lewat
   `celldm` tidak punya apa pun untuk diambil. `ibrav` 1–14 adalah rumus
   tertutup, jadi konversi bisa ditambahkan di `lib/parser.sh` tanpa mengubah
   rancangan lain.
2. **Tidak ada tes otomatis.** Untuk alat yang tugasnya menolak, penolakan yang
   tidak diuji lebih buruk daripada tidak menolak. Perintah di §3 adalah
   kandidat langsung untuk dibekukan menjadi `tests/run.sh`.
3. **Run yang terbunuh tidak dapat dilanjutkan.** `logs/<case>.status.tsv`
   sudah mencatat tahap mana yang selesai, sehingga datanya ada; yang belum ada
   adalah melewati tahap yang keluarannya sudah lengkap. `--from` menutup
   sebagian kebutuhan ini secara manual.
4. **Keempat tahap pw.x berbagi satu `outdir` dan `prefix`.** Karena itu
   `bandsx` tidak boleh diulang setelah `nscf`: fungsi gelombang yang tersimpan
   sudah milik nscf. Dapat dideteksi dari `.xml` di dalam save dir, yang
   merekam jenis kalkulasinya; saat ini belum.
5. **Tidak ada reset `work/` sebelum tahap.** `setup_case()` juga hardcode
   `mkdir -p "$INPUT_DIR/work"` walaupun `outdir` di input menunjuk ke tempat
   lain.
6. **Uji slab memakai rasio sumbu `c/a > 2.0`**, bukan sebaran koordinat z atom
   terhadap c. Benar untuk monolayer, salah untuk kristal 3D yang memang
   berlapis: grafit (c/a = 2,7) dan bulk 2H-MoS₂ (c/a = 3,9) sama-sama akan
   kehilangan dispersi Γ–A.
7. **`CASES_PARALLEL > 1` terukur jauh lebih lambat** daripada sekuensial
   (45–51 menit melawan 3m07s untuk pekerjaan yang sama). Penyebabnya belum
   ditemukan.
8. **`convergence NOT achieved` pada scf tertangkap tetapi tidak terdiagnosa.**
   `diagnose_failure()` belum punya cabang untuknya.
9. **Sapuan `runlogs/` balapan dengan job serentak.** Kosmetik.
