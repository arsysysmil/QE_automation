# QE_automation

Otomatisasi rantai perhitungan Quantum ESPRESSO. Dari satu file input
relaksasi, seluruh tahapan dikerjakan sampai selesai:

```
relax → scf → band → bands.x → nscf → dos → plot
```

Keluaran: struktur pita, DOS, gambar PNG, dan file CIF struktur sebelum dan
sesudah relaksasi.

Tanpa otomatisasi ini, tiap tahap dijalankan terpisah dan masing-masing
memerlukan file input baru yang ditulis tangan dari hasil tahap sebelumnya.
Perintahnya identik di mesin lokal maupun HPC — sistem mendeteksi lingkungannya
sendiri.

Ditulis dengan bash. Python hanya muncul sebagai keluaran, berupa skrip
penggambar yang dapat diedit sendiri.

Detail teknis — cara kerja bagian dalam, alasan tiap penolakan, seluruh isi
`config.sh`, dan batasan yang diketahui — ada di [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

# Syarat file input

Input yang tidak memenuhi syarat akan ditolak, atau lebih buruk, tetap berjalan
dengan hasil yang keliru.

**Nama file berakhiran `_relax.in`**

```
benar  : mos2_relax.in     ws2_co2_B1_relax.in
salah  : mos2.relax.in     mos2_relax.txt
```

Nama material diambil dari bagian sebelum `_relax.in`, dan semua file hasil
dinamai dari situ.

**`calculation` bernilai `relax` atau `vc-relax`**

`relax` bila bentuk sel dipertahankan, `vc-relax` bila sel ikut dioptimasi.
Nilai `scf` tetap dijalankan, tetapi posisi atom diambil dari input tanpa
pemberitahuan.

**`ibrav = 0` disertai card `CELL_PARAMETERS`**

```fortran
&SYSTEM
    ibrav = 0
/

CELL_PARAMETERS {angstrom}
3.190000000 0.000000000 0.000000000
1.595000000 2.762620000 0.000000000
0.000000000 0.000000000 20.000000000
```

Geometri dioper antar tahap sebagai `CELL_PARAMETERS`. Input dengan
`ibrav ≠ 0` mendeskripsikan kisi lewat `celldm`, sehingga tidak ada yang bisa
diambil. Input dari tutorial atau paper umumnya demikian; konversi dilakukan
lebih dulu dengan menghitung tiga vektor kisi dari `celldm`.

**`K_POINTS` bermode `automatic` atau `gamma`**

```fortran
K_POINTS {automatic}
12 12 1 0 0 0
```

Mode `crystal`, `tpiba`, dan daftar titik eksplisit ditolak: tahap nscf perlu
memperbesar mesh untuk DOS yang halus, sedangkan daftar titik eksplisit tidak
punya mesh untuk diperbesar. Molekul terisolasi memakai `K_POINTS {gamma}`
disertai `NPOOL_WANTED=1` di `config.sh`.

**Parameter wajib**

| Parameter | Namelist |
|---|---|
| `ibrav`, `nat`, `ntyp`, `ecutwfc` | `&SYSTEM` |
| `pseudo_dir` | `&CONTROL` |

Ditambah card `ATOMIC_SPECIES`, dan tiap file `.UPF` di dalamnya harus ada di
`pseudo_dir`.

**`occupations` sesuai jenis material**

| Material | Pengaturan |
|---|---|
| Logam, semimetal (graphene) | `occupations = 'smearing'` + `smearing` + `degauss` |
| Semikonduktor, insulator | `smearing` atau `fixed` |

Bila tidak ditulis, QE memakai `fixed` — keliru untuk graphene.

**Satu folder boleh berisi banyak input**, asalkan tidak ada dua yang memakai
`prefix` sama. Bila `prefix` tidak ditulis, sistem memakai nama case sehingga
hasilnya otomatis terpisah.

---

# Cara pakai

## Satu material

```bash
cd ~/QE_automation
mkdir -p cases/mos2
cp /lokasi/mos2_relax.in cases/mos2/
bash qe.sh init cases/mos2/mos2_relax.in
bash qe.sh dump cases/mos2/mos2_relax.in
bash qe.sh cases/mos2/mos2_relax.in
```

Di HPC, baris terakhir diganti:

```bash
sbatch -p medium-small -t 3-00:00:00 qe.sh cases/mos2/mos2_relax.in
squeue -u $USER
```

## Beberapa material sekaligus

Kumpulkan file `_relax.in` dalam satu folder, lalu sebut foldernya:

```bash
bash qe.sh init cases/ws2
bash qe.sh dump cases/ws2
bash qe.sh cases/ws2
```

Semua case dijalankan berurutan dalam satu job, masing-masing memperoleh
seluruh alokasi. Satu case yang gagal tidak menghentikan yang lain, dan
ringkasan di akhir menyebut tahap tempat tiap kegagalan berhenti.

Penyebutan folder tidak rekursif. Menambah file ke folder berarti menambahnya
ke runningan, tanpa daftar lain yang perlu diperbarui. Untuk sebagian isi
folder, sebut filenya satu per satu:

```bash
bash qe.sh cases/ws2/ws2_co2_B1_relax.in cases/ws2/ws2_h2s_B1_relax.in
```

## Berhenti di tahap tertentu

Pipeline dapat dihentikan di tahap mana pun dengan menambahkan nama tahap
sebagai flag. Posisinya bebas, umumnya ditulis di akhir perintah.

```bash
bash qe.sh cases/mos2 --scf          # berhenti setelah scf
bash qe.sh cases/mos2 --until=scf    # bentuk eksplisit, sama artinya
bash qe.sh cases/mos2 --relax        # relaksasi saja
```

Setelah selesai, sistem menyebut tahap yang tidak dijalankan beserta perintah
untuk melanjutkannya:

```
Stopped after 'scf', as asked.

Not run: gen-band band bandsx gen-nscf nscf dos plot
Continue with:
  bash qe.sh cases/mos2/mos2_relax.in --from=gen-band
```

`--from` memulai dari tahap tertentu, memakai hasil yang sudah ada. Keduanya
bisa digabung:

```bash
bash qe.sh cases/mos2 --from=gen-band --until=bandsx
```

Penomoran tahap menyesuaikan: `--scf` menjalankan `1/6` sampai `6/6`.

Berbeda dengan menyebut satu tahap (`bash qe.sh scf ...`) yang hanya
menjalankan tahap itu saja, flag rentang menjalankan seluruh tahap sampai atau
sejak batas yang disebut.

## Memantau dan memeriksa

```bash
squeue -u $USER
bash qe.sh check cases/mos2/mos2_relax.in
```

## Menggambar ulang tanpa mengulang perhitungan

```bash
cd cases/mos2
nano mos2_plot.py
python3 mos2_plot.py
```

## Bila gagal di tengah jalan

```bash
bash qe.sh check cases/mos2/mos2_relax.in
rm -rf cases/mos2/work cases/mos2/cache cases/mos2/logs
bash qe.sh cases/mos2/mos2_relax.in
```

Tidak ada fasilitas melanjutkan run yang terbunuh: job yang terputus
meninggalkan `work/` setengah tertulis, sehingga harus dimulai ulang dari
folder bersih.

---

# Penjelasan perintah

**`bash qe.sh init ...`** — membuat jalur band. Sistem mengukur panjang rusuk
dan sudut sel dari `CELL_PARAMETERS`, menyimpulkan jenis kisinya, lalu menulis
`mos2_band.path`:

```
Lattice measured from mos2_relax.in:
  a = 3.1900   b = 3.1900   c = 20.0000
  alpha = 90.00   beta = 90.00   gamma = 60.00
  -> hexagonal slab, gamma=60 setting  (2D: path stays at k_z = 0)

Band path written: cases/mos2/mos2_band.path
  0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
  0.5000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! M
  0.6666666667  0.3333333333  0.0000000000  __BAND_POINTS__   ! K
  0.0000000000  0.0000000000  0.0000000000   1                ! G
```

Baris `->` perlu diperiksa. Bila tertulis "tetragonal" padahal materialnya
heksagonal, ada yang keliru di `CELL_PARAMETERS`. Jalur yang salah tidak
menghasilkan error — grafiknya tetap keluar dan tampak wajar, tetapi isinya
bukan yang dimaksud. Karena itu langkah ini dipisah.

Wajib dijalankan; tanpa `<case>_band.path` pipeline berhenti di tahap 7 dari
13. Kisi yang tidak dikenali ditolak, bukan ditebak. File `.path` yang sudah
ada tidak pernah ditimpa.

**`bash qe.sh dump ...`** — memeriksa hasil pembacaan input, beberapa detik
tanpa perhitungan. Cocokkan `NAT`, `NTYP`, `ECUTWFC`, `K_POINTS`, dan nama file
pseudopotensial. Dua baris yang perlu diperhatikan:

- `note: ... using default ...` — parameter yang tidak ditulis di input dan
  diisi otomatis.
- `passthrough` — sistem mengenali 16 parameter utama; sisanya disalin apa
  adanya. Bila memakai `vdw_corr`, `nspin`, atau `nbnd`, namanya harus muncul
  di baris `&SYSTEM passthrough`. Tulisan `(none)` bukan error.

**`bash qe.sh ...` / `sbatch qe.sh ...`** — menjalankan 13 tahap berurutan:

| # | Tahap | Isinya |
|---|---|---|
| 1 | `parser` | membaca input |
| 2 | `relax` | optimasi struktur |
| 3 | `extract` | mengambil geometri hasil relaksasi |
| 4 | `cif` | menulis struktur sebelum dan sesudah relaksasi |
| 5–6 | `gen-scf`, `scf` | menghitung rapat muatan |
| 7–9 | `gen-band`, `band`, `bandsx` | energi sepanjang jalur band |
| 10–11 | `gen-nscf`, `nscf` | mesh k lebih rapat untuk DOS |
| 12 | `dos` | menghasilkan data DOS |
| 13 | `plot` | menggambar band dan DOS |

Geometri hasil relaksasi dibaca sekali di tahap `extract`, lalu dipakai ketiga
input hasil generate. Penyalinan itulah yang dihilangkan sistem ini.

**`sbatch -p medium-small -t 3-00:00:00`** — partisi dan batas waktu. Tanpa
keduanya, job memakai `short` dengan batas 24 jam sesuai header `qe.sh`, yang
cukup untuk satu case kecil.

| Partisi | Batas waktu | Node |
|---|---|---|
| `short` (bawaan) | 1 hari | 48 |
| `medium-small` | 3 hari | 22 |
| `medium-large` | 3 hari | 12 |
| `long` | 7 hari | 3 |
| `very-long` | 30 hari | 3 |
| `interactive` | 2 jam | 2 |

Pada SLURM dengan `EnforcePartLimits = NO`, `-t` yang melebihi batas partisi
**tidak ditolak** — job diterima lalu menggantung di antrean selamanya:

```
JOBID  PARTITION  ST  TIME  NODES  NODELIST(REASON)
507746 short      PD  0:00      1  (PartitionTimeLimit)
```

`PD` yang tidak berubah dengan alasan `PartitionTimeLimit` berarti `scancel`
lalu submit ulang dengan partisi yang benar. Karena itu `-p` dan `-t` selalu
diubah berpasangan; sepuluh case dengan ~6,5 jam per case memerlukan sekitar
65 jam, jadi `-p medium-small -t 3-00:00:00`.

Penyesuaian dilakukan lewat baris perintah, bukan dengan mengedit `qe.sh`,
karena file itu harus tetap identik di semua mesin. Batas yang benar-benar
berlaku dicetak di kepala log.

**`bash qe.sh check ...`** — menampilkan sampai tahap mana sebuah run berjalan,
apa yang gagal, dan penyebabnya. Berguna terutama bila job dibunuh batas waktu:
log SLURM berhenti di tengah kalimat, sedangkan `check` menyebut tahap yang
terputus.

**Menjalankan satu tahap saja:**

```bash
bash qe.sh scf  cases/mos2/mos2_relax.in
bash qe.sh plot cases/mos2/mos2_relax.in
bash qe.sh                                 # daftar lengkap tahap
```

Satu pengecualian: `bandsx` tidak boleh diulang setelah `nscf`. Keempat tahap
pw.x berbagi satu `outdir`, sehingga setelah pipeline selesai, fungsi gelombang
yang tersimpan milik nscf. Ulangi dari `band` bila perlu.

---

# Hasil

```
cases/mos2/
├── mos2_band.png          gambar band structure
├── mos2_dos.png           gambar DOS
├── mos2_band_dos.png      keduanya berdampingan, satu sumbu energi
├── mos2_plot.py           skrip yang menggambar ketiganya
├── mos2_initial.cif       struktur sebelum relaksasi
├── mos2_relaxed.cif       struktur sesudah relaksasi
├── mos2.bands.dat.gnu     data band
└── mos2.dos               data DOS
```

Angka 0 pada sumbu tegak menandai E_Fermi, digambar sebagai garis putus-putus
merah. Nilainya diambil dari run **nscf**: mesh k-nya paling rapat, dan itu
pula yang ditulis `dos.x` ke header DOS, sehingga kedua panel memakai nol yang
sama dengan data DOS.

Kedua file CIF dapat dibuka di VESTA untuk membandingkan struktur sebelum dan
sesudah relaksasi. Simetrinya ditulis `P 1`, bukan ditebak dari koordinat hasil
relaksasi — grup ruang yang ditebak menghasilkan CIF yang salah tanpa pesan
apa pun. VESTA mendeteksi simetrinya sendiri.

## Menyetel ulang gambar

Bagian atas `mos2_plot.py` berisi blok pengaturan:

```python
E_FERMI    = -2.0755
EMIN, EMAX = -5.0, 5.0
LABELS     = ["G", "M", "K", "G"]
DPI        = 300
```

Menjalankan ulang skrip ini hanya membaca data yang sudah jadi, selesai dalam
hitungan detik, dan tidak mengulang perhitungan DFT.

`EMIN, EMAX` adalah batas sumbu tegak. Angka yang tampak di gambar (misalnya
±4) merupakan label tick matplotlib, bukan batas sumbu. Bawaan untuk case baru
diatur lewat `PLOT_EMIN` / `PLOT_EMAX` di `config.sh`.

Untuk material bergap, `E_FERMI` sebaiknya diisi nilai VBM: dengan smearing,
E_Fermi ditempatkan di dekat tepi pita, bukan di tengah gap. Lebar gap juga
sebaiknya dibaca dari data pita, bukan dari grafik DOS, karena pelebaran pada
DOS membuat gap terbaca lebih sempit.

Menjalankan ulang `qe.sh plot` akan menimpa skrip ini.

## Jumlah pita (`nbnd`)

Bila input tidak menulis `nbnd`, QE memakai bawaannya:

| `occupations` | `nbnd` bawaan QE |
|---|---|
| `fixed` | `nelec/2` persis — nol pita konduksi |
| `smearing` | `max(1,2 × nelec/2, nelec/2 + 4)` |

Pada `fixed`, separuh atas grafik band dan DOS kosong sama sekali karena tidak
ada pita di atas tingkat Fermi yang dihitung. Perhitungannya selesai dengan
sukses; hasilnya saja yang tidak dapat dipakai.

Karena itu tahap `gen-band` dan `gen-nscf` menghitung sendiri:

```
nbnd = max(AUTO_NBND_FACTOR × jumlah pita terisi, jumlah pita terisi + 4)
```

`AUTO_NBND_FACTOR` ada di `config.sh` dengan bawaan 1,5; isi `0` untuk
mematikan. Tahap `scf` tidak diberi, karena pita kosong hanya menambah waktu.
Keluarannya:

```
  note: nbnd absent from input - band uses nbnd = 20
        (26.00 electrons, 13 occupied bands, x1.5).
        QE's own default here would be 13, which leaves 0 band(s)
        above the Fermi level.
```

`nbnd` yang ditulis sendiri di `&SYSTEM` selalu menang, dan catatan itu tidak
dicetak.

Nilai bawaan perlu dinaikkan pada slab dengan vakum tebal, karena sebagian pita
kosongnya terpakai untuk keadaan vakum terkuantisasi, bukan untuk materialnya.
Pada graphene dengan vakum 20 Å, keadaan tersebut muncul di sekitar +3 sampai
+5 eV dan menggeser pita σ*/π* asli ke luar jangkauan. Jumlah yang benar-benar
dipakai dapat diperiksa dengan:

```bash
grep "Kohn-Sham states" cases/mos2/mos2_scf.out
```

## Kasus magnetik

Pada input dengan `nspin = 2`, `bands.x` dijalankan dua kali, sekali per kanal
spin, dan grafik band menggambar keduanya: spin up garis penuh, spin down garis
putus, sewarna dengan panel DOS di sebelahnya. Kasus non-magnetik tidak
terpengaruh.

---

# Pemeriksaan

## Yang diperiksa sistem

Bila salah satu tidak terpenuhi, sistem berhenti seketika dengan pesan yang
menyebut penyebab dan solusinya, sebelum ada perhitungan yang terlanjur jalan.

- Nama file, `ibrav = 0`, `CELL_PARAMETERS`, mode `K_POINTS`, parameter wajib
- **Pseudopotensial tersedia di `pseudo_dir`** — diperiksa untuk semua case
  sekaligus sebelum antre, karena pw.x baru menemukannya beberapa detik setelah
  job mulai, yaitu setelah antre berjam-jam
- **Tidak ada dua case dalam satu folder yang memakai `prefix` sama**
- **Relaksasi benar-benar konvergen** — pw.x mencetak `JOB DONE.` walaupun BFGS
  kehabisan langkah ionik, sehingga ini diperiksa terpisah. Bila tidak
  konvergen, pipeline berhenti di tahap 2 dari 13. Cara melanjutkan: salin
  `ATOMIC_POSITIONS` terakhir dari output ke input, naikkan `nstep`, jalankan
  lagi.
- **File hasil tidak lebih tua dari sumbernya** — input yang diedit dibaca
  ulang otomatis. Bila `<case>_band.path` diperbaiki lalu `band` dijalankan
  tanpa `gen-band`, sistem berhenti, karena pw.x akan menyusuri jalur-k lama
  dan menghasilkan grafik yang rapi tetapi salah. Sebaliknya, `<case>_scf.in`
  yang diedit sendiri tetap dipakai karena menjadi file termuda.

## Yang tidak diperiksa sistem

Bagian ini paling sering menimbulkan masalah: tidak ada error, perhitungan
selesai dengan sukses, tetapi hasilnya keliru.

- **Konvergensi parameter** — ketebalan vakum, kecukupan `ecutwfc`, kerapatan
  mesh k, rasio `ecutrho/ecutwfc` (pseudopotensial PAW memerlukan 8–10×, bukan
  bawaan 4×). Uji konvergensi dilakukan terpisah, sebelum memakai sistem ini.
- **Kebenaran jalur band** — diperiksa sendiri lewat keluaran `init`.
- **Kecukupan `nbnd` otomatis** — angkanya aturan praktis, bukan hasil uji
  konvergensi.

---

# Catatan mesin

| | Lokal | HPC |
|---|---|---|
| Menjalankan | `bash qe.sh` | `sbatch qe.sh` |
| Jumlah proses | core fisik, terdeteksi otomatis | dari alokasi SLURM |
| `pw.x` | dari `PATH` | dari module |

File `qe.sh`, `config.sh`, dan seluruh `lib/` identik di kedua lingkungan,
karena keduanya mendeteksi lingkungannya sendiri. Periksa dengan
`md5sum qe.sh config.sh lib/*.sh`; perbedaan berarti bug, bukan setting.

Bila HPC tidak memiliki matplotlib maupun gnuplot, tahap `plot` dilewati
disertai pesan penjelasan dan perhitungan tetap dinyatakan berhasil — hanya
gambarnya yang tidak dibuat. Salin folder materialnya ke mesin lokal:

```bash
scp -r <hpc>:<folder-kerja>/QE_automation/cases/mos2 ~/QE_automation/cases/
bash qe.sh plot cases/mos2/mos2_relax.in
```

---

# Struktur file

```
qe.sh          orkestrator: path, config, daftar tahap, dan menjalankannya
config.sh      seluruh pengaturan yang dapat diubah
lib/           satu file per urusan, di-source menjadi satu proses
template/      contoh jalur band, tidak dipakai otomatis
ARCHITECTURE.md   detail teknis
```

Belum diimplementasikan: PDOS dan work function. `projwfc.x`, `pp.x`, dan
`average.x` sudah dideklarasikan di `config.sh` untuk keduanya.
