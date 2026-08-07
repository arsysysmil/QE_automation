# QE_automation

Menjalankan rantai perhitungan Quantum ESPRESSO secara otomatis. Dari satu file
input relaksasi, seluruh tahapan dikerjakan sampai selesai:

```
relax → scf → band → bands.x → nscf → dos → plot
```

Hasil akhir: struktur pita, DOS, gambar PNG, dan file CIF struktur sebelum dan
sesudah relaksasi.

Tanpa ini, tiap tahap dijalankan satu per satu, dan tiap tahap butuh file input
baru yang ditulis tangan dari hasil tahap sebelumnya. Perintahnya sama persis
di laptop maupun di HPC — sistem mendeteksi mesinnya sendiri, bukan
dikonfigurasi terpisah.

Ditulis dengan bash. Python hanya muncul sebagai *keluaran*, yaitu skrip
penggambar yang bisa diedit sendiri.

Penjelasan teknis lebih dalam — apa yang ditolak sistem beserta alasannya,
seluruh pengaturan di `config.sh`, cara menambah tahap baru, dan batasan yang
diketahui — ada di [`REFERENSI.md`](REFERENSI.md).

---

# Syarat file input

Baca dulu sebelum menjalankan apa pun. Input yang tidak memenuhi syarat akan
ditolak sistem, atau lebih buruk, tetap berjalan tetapi hasilnya keliru.

**Nama file harus berakhiran `_relax.in`**

```
benar  : mos2_relax.in     ws2_co2_B1_relax.in
salah  : mos2.relax.in     mos2_relax.txt
```

Garis bawah, bukan titik. Nama material diambil dari bagian sebelum
`_relax.in`, dan semua file hasil dinamai dari situ.

**`calculation` harus `relax` atau `vc-relax`**

Pakai `relax` bila bentuk sel dipertahankan, `vc-relax` bila sel ikut
dioptimasi. Kalau ditulis `scf`, sistem tetap jalan tapi posisi atom diambil
dari input tanpa pemberitahuan.

**`ibrav = 0`, ditulis eksplisit, disertai card `CELL_PARAMETERS`**

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
`ibrav ≠ 0` mendeskripsikan kisi lewat `celldm`, jadi tidak ada yang bisa
diambil. Input dari tutorial atau paper umumnya begitu — konversikan dulu:
hitung tiga vektor kisi dari `celldm`, tulis sebagai card, set `ibrav = 0`.

**`K_POINTS` harus `automatic` atau `gamma`**

```fortran
K_POINTS {automatic}
12 12 1 0 0 0
```

Bentuk `crystal`, `tpiba`, dan daftar titik eksplisit ditolak. Tahap nscf perlu
memperbesar mesh ini untuk DOS yang halus, sedangkan daftar titik eksplisit
tidak punya mesh untuk diperbesar. Untuk molekul terisolasi pakai
`K_POINTS {gamma}` disertai `NPOOL_WANTED=1` di `config.sh`.

**Parameter yang wajib ada**

| Parameter | Namelist |
|---|---|
| `ibrav`, `nat`, `ntyp`, `ecutwfc` | `&SYSTEM` |
| `pseudo_dir` | `&CONTROL` |

Ditambah card `ATOMIC_SPECIES`, dan file `.UPF` yang disebut di dalamnya harus
benar-benar ada di `pseudo_dir`.

**`occupations` harus sesuai jenis material**

| Material | Pengaturan |
|---|---|
| Logam, semimetal (graphene) | `occupations = 'smearing'` + `smearing` + `degauss` |
| Semikonduktor, insulator | `smearing` atau `fixed` |

Kalau tidak ditulis, QE memakai `fixed`. Untuk graphene itu keliru.

**Satu folder boleh berisi banyak file**, asal tiap input tidak menuliskan
`prefix` yang sama. Kalau `prefix` tidak ditulis sama sekali, sistem memakai
nama case, dan hasilnya otomatis terpisah.

---

# Cara pakai

## Skema 1 — satu material

Di laptop:

```bash
cd ~/QE_automation
mkdir -p cases/mos2
cp /lokasi/mos2_relax.in cases/mos2/
bash qe.sh init cases/mos2/mos2_relax.in
bash qe.sh dump cases/mos2/mos2_relax.in
bash qe.sh cases/mos2/mos2_relax.in
```

Di HPC:

```bash
cd <folder-kerja>/QE_automation
mkdir -p cases/mos2
cp /lokasi/mos2_relax.in cases/mos2/
bash qe.sh init cases/mos2/mos2_relax.in
bash qe.sh dump cases/mos2/mos2_relax.in
sbatch -p medium-small -t 3-00:00:00 qe.sh cases/mos2/mos2_relax.in
squeue -u $USER
```

Yang berbeda hanya baris terakhir: `bash` di laptop, `sbatch` di HPC.

## Skema 2 — beberapa material sekaligus

Taruh semua file `_relax.in` dalam satu folder, lalu sebut foldernya.

```bash
cd ~/QE_automation
mkdir -p cases/ws2
cp /lokasi/ws2_*_relax.in cases/ws2/
bash qe.sh init cases/ws2
bash qe.sh dump cases/ws2
bash qe.sh cases/ws2
```

Di HPC baris terakhir diganti:

```bash
sbatch -p medium-small -t 3-00:00:00 qe.sh cases/ws2
```

Semua case dijalankan berurutan dalam satu job, masing-masing mendapat seluruh
alokasi. Satu case yang gagal tidak menghentikan yang lain, dan di akhir
dicetak ringkasan yang menyebut tahap tempat tiap kegagalan berhenti.

Menyebut folder tidak rekursif: folder yang disebut itulah yang dijalankan,
sub-foldernya tidak ikut. Menambah file ke folder berarti menambahnya ke
runningan, tanpa ada daftar lain yang perlu diperbarui.

Kalau tidak mau seluruh isi folder, sebut filenya satu per satu:

```bash
bash qe.sh cases/ws2/ws2_co2_B1_relax.in cases/ws2/ws2_h2s_B1_relax.in
```

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

## Kalau gagal di tengah jalan

```bash
bash qe.sh check cases/mos2/mos2_relax.in
rm -rf cases/mos2/work cases/mos2/cache cases/mos2/logs
bash qe.sh cases/mos2/mos2_relax.in
```

Tidak ada fasilitas melanjutkan dari tengah — job yang terputus meninggalkan
`work/` setengah tertulis, jadi mulai ulang dengan folder yang sudah bersih.

---

# Penjelasan

## Arti tiap perintah

**`mkdir -p cases/mos2`** — folder untuk satu material. Semua file, input
sampai gambar, berada di dalamnya.

Nama `cases/` cuma kebiasaan, bukan keharusan. `qe.sh` menerima path mana pun,
jadi folder data yang sudah ada bisa langsung ditunjuk:

```bash
bash qe.sh init ../ws2/semua_TS
sbatch -p medium-small -t 3-00:00:00 qe.sh ../ws2/semua_TS
```

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

Periksa baris `->`. Kalau tertulis "tetragonal" padahal materialnya heksagonal,
berarti ada yang keliru di `CELL_PARAMETERS`. Jalur yang salah tidak
menghasilkan error — grafiknya tetap keluar dan tampak wajar, tapi isinya bukan
yang dimaksud. Karena itu langkah ini dipisah, supaya bisa diperiksa dulu.

Wajib dijalankan. Tanpa `<case>_band.path`, pipeline berhenti di tahap 7 dari
13. Kalau kisinya tidak dikenali, sistem menolak menebak dan meminta jalurnya
ditulis manual. File `.path` yang sudah ada tidak pernah ditimpa.

**`bash qe.sh dump ...`** — memeriksa pembacaan input. Gratis, beberapa detik,
tanpa perhitungan. Cocokkan `NAT`, `NTYP`, `ECUTWFC`, `K_POINTS`, dan nama file
pseudopotensial dengan yang dimaksud.

Dua baris yang perlu diperhatikan:

- `note: ... using default ...` — ada parameter yang tidak ditulis di input dan
  diisi otomatis. Pastikan nilai bawaannya memang sesuai.
- `passthrough` — sistem mengenali 16 parameter utama; sisanya disalin apa
  adanya ke tahap berikutnya. Kalau memakai `vdw_corr`, `nspin`, atau `nbnd`,
  namanya harus muncul di baris `&SYSTEM passthrough`. Tulisan `(none)` berarti
  tidak ada parameter tambahan, bukan error.

Tidak wajib, tapi murah dan sering menyelamatkan.

**`bash qe.sh ...` / `sbatch qe.sh ...`** — menjalankan seluruh pipeline, 13
tahap berurutan:

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

Tiap tahap mencetak waktu mulai, selesai, dan durasinya. Selesai bila muncul
`Workflow Finished Successfully`.

Geometri hasil relaksasi dibaca satu kali di tahap `extract`, lalu dipakai
ulang oleh ketiga input hasil generate. Penyalinan itulah yang ingin dihapus
sistem ini.

**`sbatch -p medium-small -t 3-00:00:00`** — partisi dan batas waktu.

Tanpa keduanya kamu dapat `short` dengan batas 24 jam, sesuai header `qe.sh`.
Itu jalan normal, bukan gagal — cukup untuk satu case kecil.

Partisi yang tersedia:

| Partisi | Batas waktu | Node |
|---|---|---|
| `short` (bawaan) | 1 hari | 48 |
| `medium-small` | 3 hari | 22 |
| `medium-large` | 3 hari | 12 |
| `long` | 7 hari | 3 |
| `very-long` | 30 hari | 3 |
| `interactive` | 2 jam | 2 |

**Perangkap yang perlu diketahui:** kalau `-t` dinaikkan tapi partisinya lupa
diganti, SLURM dengan `EnforcePartLimits = NO` **tidak menolak** — job
diterima, lalu menggantung di antrean selamanya.

Cirinya di `squeue` kolom paling kanan:

```
JOBID  PARTITION  ST  TIME  NODES  NODELIST(REASON)
507746 short      PD  0:00      1  (PartitionTimeLimit)
```

`PD` yang tidak pernah berubah, dengan alasan `PartitionTimeLimit`. Kalau
melihat itu, `scancel` lalu submit ulang dengan partisi yang benar.

Jadi `-p` dan `-t` selalu diubah **berpasangan**. Perkirakan dulu total
waktunya: sepuluh case dengan ~6,5 jam per case butuh sekitar 65 jam, jadi
`-p medium-small -t 3-00:00:00`.

Sesuaikan lewat baris perintah, jangan mengedit `qe.sh`, karena file itu harus
tetap identik di laptop dan HPC. Batas yang benar-benar berlaku dicetak di
kepala log.

**`bash qe.sh check ...`** — menampilkan sampai tahap mana sebuah run berjalan,
apa yang gagal, dan kenapa. Berguna terutama kalau job dibunuh batas waktu:
log SLURM berhenti di tengah kalimat, sedangkan `check` menyebut tahap ke
berapa yang terputus.

**Menjalankan satu tahap saja**, untuk mencari kesalahan:

```bash
bash qe.sh scf  cases/mos2/mos2_relax.in
bash qe.sh plot cases/mos2/mos2_relax.in
bash qe.sh cif  cases/mos2/mos2_relax.in
bash qe.sh                                 # daftar lengkap tahap
```

Satu pengecualian: **`bandsx` tidak boleh diulang setelah `nscf`**. Keempat
tahap pw.x berbagi satu `outdir`, jadi begitu pipeline selesai, fungsi
gelombang yang tersimpan adalah milik nscf. Ulangi dari `band` kalau perlu.

## Hasil

Semuanya di dalam folder material:

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

Pada semua gambar, angka 0 di sumbu tegak menandai E_Fermi, digambar sebagai
garis putus-putus merah. Nilainya diambil dari run **nscf** — mesh k-nya paling
rapat, dan itu pula yang ditulis `dos.x` ke header DOS, jadi kedua panel
memakai nol yang sama dengan data DOS-nya sendiri.

Kedua file CIF bisa langsung dibuka di VESTA untuk membandingkan struktur
sebelum dan sesudah relaksasi. Simetrinya sengaja ditulis `P 1`, bukan ditebak
dari koordinat hasil relaksasi — grup ruang yang ditebak menghasilkan CIF yang
salah tanpa pesan apa pun. VESTA bisa mendeteksi simetrinya sendiri.

## Menyetel ulang gambar

Bagian atas `mos2_plot.py` berisi blok pengaturan yang bebas diubah:

```python
E_FERMI    = -2.0755
EMIN, EMAX = -5.0, 5.0
LABELS     = ["G", "M", "K", "G"]
DPI        = 300
```

Menjalankan ulang skrip itu tidak mengulang perhitungan DFT — hanya membaca
data yang sudah jadi, selesai dalam hitungan detik.

`EMIN, EMAX` itulah batas sumbu tegak. Angka yang tampak di gambar (misalnya
±4) adalah label tick matplotlib, bukan batas sumbunya. Untuk mengubah bawaan
semua case baru, ubah `PLOT_EMIN` / `PLOT_EMAX` di `config.sh`.

Untuk material bergap, sebaiknya `E_FERMI` diisi nilai VBM (puncak pita
valensi), bukan E_Fermi. Dengan smearing, E_Fermi ditempatkan di dekat tepi
pita, bukan di tengah gap. Lebar gap juga sebaiknya dibaca dari data pita,
bukan dari grafik DOS — pelebaran pada DOS membuat gap terbaca lebih sempit.

Catatan: menjalankan ulang `qe.sh plot` akan **menimpa** skrip ini.

## Berapa pita yang dihitung (`nbnd`)

Kalau input tidak menulis `nbnd`, QE memakai bawaannya:

| `occupations` | `nbnd` bawaan QE |
|---|---|
| `fixed` | `nelec/2` **persis** — nol pita konduksi |
| `smearing` | `max(1,2 × nelec/2, nelec/2 + 4)` |

Untuk `fixed` itu berarti separuh atas grafik band dan DOS **kosong sama
sekali**, karena memang tidak ada pita di atas tingkat Fermi yang dihitung.
Ini bukan error: perhitungannya selesai dengan sukses, hasilnya saja yang tidak
bisa dipakai.

Karena itu tahap `gen-band` dan `gen-nscf` menghitung sendiri:

```
nbnd = max(AUTO_NBND_FACTOR × jumlah pita terisi, jumlah pita terisi + 4)
```

`AUTO_NBND_FACTOR` ada di `config.sh`, bawaannya 1,5. Isi `0` untuk mematikan.
Tahap `scf` sengaja tidak diberi — pita kosong hanya menambah waktu di sana.

Yang dicetak di layar:

```
  note: nbnd absent from input - band uses nbnd = 20
        (26.00 electrons, 13 occupied bands, x1.5).
        QE's own default here would be 13, which leaves 0 band(s)
        above the Fermi level. Set nbnd in &SYSTEM to choose your own,
        or AUTO_NBND_FACTOR in config.sh to change this rule.
```

**Menulis `nbnd` sendiri di `&SYSTEM` selalu menang** — kalau ada, sistem tidak
menambahkan apa pun dan tidak mencetak catatan itu.

Kapan perlu dinaikkan sendiri: slab dengan vakum tebal menghabiskan sebagian
pita kosongnya untuk *keadaan vakum terkuantisasi*, bukan untuk materialnya.
Untuk graphene dengan vakum 20 Å, keadaan itu muncul di sekitar +3 sampai
+5 eV dan menggeser pita σ*/π* asli ke luar jangkauan. Kalau pita konduksi yang
dicari tidak muncul di grafik, naikkan `nbnd`.

Memeriksa berapa yang benar-benar dipakai:

```bash
grep "Kohn-Sham states" cases/mos2/mos2_scf.out
```

## Kasus magnetik

Kalau input menulis `nspin = 2`, `bands.x` dijalankan dua kali, sekali per
kanal spin, dan grafik band menggambar keduanya: spin up garis penuh, spin down
garis putus, warnanya sama dengan panel DOS di sebelahnya.

Kasus non-magnetik tidak berubah sama sekali.

## Yang diperiksa sistem

Kalau salah satu tidak dipenuhi, sistem berhenti seketika dengan pesan yang
menyebut penyebab dan solusinya, tanpa ada perhitungan yang terlanjur jalan.

- Nama file, `ibrav = 0`, `CELL_PARAMETERS`, bentuk `K_POINTS`, parameter wajib
- **Pseudopotensial ada di `pseudo_dir`** — diperiksa untuk semua case sekaligus
  sebelum antre, karena pw.x baru menemukannya beberapa detik setelah job mulai,
  yaitu setelah antre berjam-jam
- **Dua case dalam satu folder tidak memakai `prefix` yang sama**
- **Relaksasi benar-benar konvergen** — pw.x mencetak `JOB DONE.` walaupun BFGS
  kehabisan langkah ionik, jadi ini diperiksa terpisah setelah relax selesai.
  Kalau tidak konvergen, pipeline berhenti di tahap 2 dari 13, sebelum scf.
  Cara melanjutkan: salin `ATOMIC_POSITIONS` terakhir dari output ke input,
  naikkan `nstep`, jalankan lagi — jangan mulai dari nol.
- **File hasil tidak lebih tua dari sumbernya** — kalau input diedit, sistem
  membaca ulang otomatis. Kalau `<case>_band.path` diperbaiki lalu `band`
  dijalankan langsung tanpa `gen-band`, sistem berhenti, karena pw.x akan
  menyusuri jalur-k lama dan menghasilkan grafik yang rapi tapi salah.
  Sebaliknya kalau kamu mengedit sendiri `<case>_scf.in`, editanmu yang
  termuda, jadi tetap dipakai.

## Yang tidak diperiksa sistem

Bagian ini yang paling sering menimbulkan masalah: tidak ada error, perhitungan
selesai dengan sukses, tapi hasilnya keliru.

- **Konvergensi parameter.** Ketebalan vakum, kecukupan `ecutwfc`, kerapatan
  mesh k, rasio `ecutrho/ecutwfc` (pseudopotensial PAW butuh 8–10×, bukan
  bawaan 4×). Nilai yang terlalu kecil menghasilkan perhitungan yang selesai
  dengan sukses namun tidak bermakna. Uji konvergensi dilakukan terpisah,
  sebelum memakai sistem ini.
- **Kebenaran jalur band.** Diperiksa mata sendiri lewat `init`.
- **Kecukupan `nbnd` yang dihitung otomatis.** Angkanya aturan praktis, bukan
  hasil uji konvergensi.

## Catatan mesin

| | Laptop | HPC |
|---|---|---|
| Menjalankan | `bash qe.sh` | `sbatch qe.sh` |
| Jumlah proses | core fisik, terdeteksi otomatis | dari alokasi SLURM |
| `pw.x` | dari `PATH` | dari module |

File `qe.sh`, `config.sh`, dan seluruh `lib/` identik di kedua mesin. Keduanya
mendeteksi lingkungannya sendiri, bukan dikonfigurasi terpisah. Periksa dengan
`md5sum qe.sh config.sh lib/*.sh` — kalau berbeda, itu bug, bukan setting.

Kalau HPC tidak punya matplotlib maupun gnuplot, tahap `plot` dilewati disertai
pesan penjelasan, dan perhitungan tetap dinyatakan berhasil — hanya gambarnya
yang tidak dibuat. Salin folder materialnya ke laptop lalu gambar di sana:

```bash
scp -r <hpc>:<folder-kerja>/QE_automation/cases/mos2 ~/QE_automation/cases/
cd ~/QE_automation
bash qe.sh plot cases/mos2/mos2_relax.in
```

---

# Struktur file

```
qe.sh          orkestrator: path, config, daftar tahap, dan menjalankannya
config.sh      seluruh pengaturan yang boleh diubah
lib/           satu file per urusan, di-source jadi satu proses
template/      contoh jalur band, TIDAK dipakai otomatis
REFERENSI.md   rujukan teknis
```

Belum diimplementasikan: PDOS dan work function. `projwfc.x`, `pp.x`, dan
`average.x` sudah dideklarasikan di `config.sh` untuk keduanya.
