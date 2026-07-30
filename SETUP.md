# Cara Pakai QE Workflow

Dari satu file input relax, workflow ini menjalankan seluruh rantai perhitungan
sampai jadi **band structure**, **DOS**, dan **gambarnya**.

Dokumen ini tiga bagian:

1. **Urutan perintah** — ringkas, tinggal salin
2. **Urutan perintah beserta penjelasan** — apa yang terjadi, apa yang muncul, artinya apa
3. **Disclaimer** — syarat mutlak yang harus dipenuhi sebelum masuk automasi

**Baca Bagian 3 lebih dulu kalau ini pertama kalinya.** Input yang tidak
memenuhi syarat di situ akan ditolak, dan lebih cepat memperbaikinya sekarang
daripada setelah perhitungan jalan.

---

# BAGIAN 1 — Urutan Perintah

Contoh untuk material bernama `mos2`. Ganti `mos2` dengan nama materialmu.

## Di laptop

```bash
cd ~/QE_workflow
mkdir -p cases/mos2
cp /lokasi/file/mos2_relax.in cases/mos2/
bash qe.sh init cases/mos2/mos2_relax.in
bash qe.sh dump cases/mos2/mos2_relax.in
bash qe.sh      cases/mos2/mos2_relax.in
```

## Di cluster (SLURM)

```bash
cd _scratch/arsy/QE_workflow_v2
mkdir -p cases/mos2
cp /lokasi/file/mos2_relax.in cases/mos2/
bash   qe.sh init cases/mos2/mos2_relax.in
bash   qe.sh dump cases/mos2/mos2_relax.in
sbatch qe.sh      cases/mos2/mos2_relax.in
squeue -u $USER
```

Bedanya hanya baris terakhir: `bash` di laptop, `sbatch` di cluster. `init` dan
`dump` selalu pakai `bash` — keduanya ringan dan tidak butuh antrian.

## Kalau ada yang gagal

```bash
bash qe.sh check cases/mos2/mos2_relax.in
rm -rf cases/mos2/{work,cache,logs}
```

## Menyetel ulang gambar (tanpa hitung ulang)

```bash
cd cases/mos2
nano mos2_plot.py
python3 mos2_plot.py
```

---

# BAGIAN 2 — Urutan Perintah Beserta Penjelasan

## 1. Masuk ke folder workflow

```bash
cd ~/QE_workflow
```

Semua perintah dijalankan dari sini, bukan dari dalam folder case. Path input
selalu ditulis relatif dari sini (`cases/mos2/mos2_relax.in`).

## 2. Buat folder untuk material

```bash
mkdir -p cases/mos2
```

**Satu material = satu folder.** Ini wajib, bukan sekadar kerapian: file hasil
akhir selalu bernama `pwscf.dos` dan `pwscf.bands.dat.gnu` (dari `prefix`
bawaan QE), jadi dua material dalam satu folder akan saling menimpa hasilnya
tanpa peringatan apa pun.

## 3. Masukkan file input

```bash
cp /lokasi/file/mos2_relax.in cases/mos2/
```

Nama file **harus** berakhiran `_relax.in` dengan garis bawah. `mos2.relax.in`
akan ditolak. Alasannya ada di Bagian 3.

## 4. Buat jalur band

```bash
bash qe.sh init cases/mos2/mos2_relax.in
```

**Apa yang dikerjakan:** membaca `CELL_PARAMETERS` dari inputmu, mengukur
panjang tiga rusuk dan tiga sudutnya, menyimpulkan jenis kisinya, lalu menulis
`mos2_band.path` berisi rute titik-titik simetri yang sesuai.

**Kenapa perlu:** band structure adalah grafik energi versus arah dalam
kristal. Arah itu ruang 3 dimensi, tidak mungkin digambar semua — jadi
dipilihlah satu rute melewati titik istimewa. Rute ini berbeda untuk tiap
bentuk kristal, dan **kalau rutenya salah QE tidak akan error sama sekali**.
Grafiknya tetap keluar dan tetap terlihat wajar, tapi isinya bukan yang kamu
maksud. Ini pernah terjadi di project ini: label "K" pernah jatuh di titik yang
salah dan puncak Dirac graphene hilang tanpa satu pun pesan peringatan.

**Yang muncul:**

```
Lattice measured from mos2_relax.in:
  a = 3.1900   b = 3.1900   c = 20.0000
  alpha = 90.00   beta = 90.00   gamma = 60.00
  -> hexagonal slab, gamma=60 setting  (2D: path stays at k_z = 0)

Band path written: cases/mos2/mos2_band.path
  K_POINTS crystal_b
  4
  0.0000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! G
  0.5000000000  0.0000000000  0.0000000000  __BAND_POINTS__   ! M
  0.6666666667  0.3333333333  0.0000000000  __BAND_POINTS__   ! K
  0.0000000000  0.0000000000  0.0000000000   1                ! G
```

**Cara membacanya:**

| Bagian | Arti |
|---|---|
| `a b c` dan `alpha beta gamma` | hasil pengukuran sel dari inputmu |
| baris `->` | **kesimpulan jenis kisi — ini yang wajib kamu periksa** |
| tiga angka tiap baris | koordinat titik simetri (pecahan, relatif kisi resiprok) |
| `! G`, `! M`, `! K` | nama titik; nanti jadi label sumbu-x di gambar. `G` = Γ |
| `__BAND_POINTS__` | tempat kosong, nanti diganti `40` (nilai `BAND_POINTS` di `config.sh`) = jumlah titik antara baris ini dan berikutnya |
| angka `1` di baris terakhir | titik akhir, tidak ada segmen setelahnya |
| angka `0` (kalau ada) | **lompat** — rute putus di sini lalu menyambung lagi. Ini arti tanda koma pada label seperti `U,K` |

**Yang wajib kamu pastikan — dua hal, dan keduanya butuh matamu:**

1. **Baris `->` cocok dengan materialmu?** Kamu tahu MoS2 itu heksagonal. Kalau
   tertulis "tetragonal", berarti ada yang salah di `CELL_PARAMETERS`-mu.
2. **Rutenya memang yang ingin kamu tampilkan?** Ini rute standar untuk kisi
   tersebut, belum tentu rute yang dipakai paper pembandingmu. Kalau ingin
   membandingkan berdampingan dengan gambar orang lain, samakan rutenya.

Kisi yang dikenali: heksagonal (setting γ=60 dan γ=120), kubik sederhana, FCC,
BCC, tetragonal, ortorombik. Heksagonal, tetragonal dan ortorombik
masing-masing punya varian 3D dan varian slab 2D — dipilih otomatis dari
`c/a > 2`, sehingga jalur untuk slab tidak menyusuri arah vakum.

Kalau kisimu **tidak dikenali**, `init` menolak menebak dan menyuruhmu menulis
sendiri. Itu disengaja.

**`init` tidak akan pernah menimpa `band.path` yang sudah ada.** Jadi rute
tulisan tanganmu selalu menang. Kalau ingin membuat ulang dari nol, hapus dulu
file `.path`-nya.

## 5. Periksa hasil pembacaan input

```bash
bash qe.sh dump cases/mos2/mos2_relax.in
```

**Apa yang dikerjakan:** membaca file inputmu persis seperti yang nanti dibaca
workflow, lalu menampilkan hasil bacaannya. Gratis, tanpa MPI, beberapa detik.

**Kenapa perlu:** semua salah ketik ketahuan **sekarang**, bukan setelah
perhitungan jalan berjam-jam.

**Yang muncul:**

```
  passthrough &CONTROL: tstress tprnfor
  passthrough &ELECTRONS: mixing_mode
Parser cache saved:
/home/arsy54/QE_workflow/cases/mos2/cache/parser.cache

PREFIX        : pwscf
OUTDIR        : ./work
PSEUDO_DIR    : /home/arsy54/QE/pseudo
CALCULATION   : relax
IBRAV         : 0
NAT           : 3
...
&SYSTEM passthrough:
  (none)
cards carried over:
  (none)
```

**Cara membacanya:**

**Daftar parameter di tengah** — cocokkan `NAT`, `NTYP`, `ECUTWFC`,
`K_POINTS`, dan nama file pseudo dengan yang kamu maksud.

**Baris `note: ... using default ...`** — kalau ada, artinya ada parameter yang
**tidak kamu tulis** dan diisi otomatis oleh workflow. Perhatikan baik-baik.
Yang paling sering menggigit: `occupations` yang tidak ditulis akan jadi
`'fixed'`, dan itu **salah untuk logam maupun semimetal** seperti graphene.
Kalau tidak ada baris `note:` sama sekali, berarti semua parameter datang dari
inputmu sendiri — itu kondisi terbaik.

**Baris `passthrough`** — parser hanya "mengerti" 16 parameter (yang tampil di
daftar tengah itu). Parameter di luar 16 itu tidak dibuang, tapi **disalin apa
adanya** ke tahap scf/band/nscf. Itulah passthrough.

Ini penting karena dulu pernah jadi bug serius: `vdw_corr` dan `nspin` hilang
diam-diam, sehingga SCF memakai koreksi dispersi tapi band structure tidak —
fisika berbeda, tanpa satu pun pesan error.

`(none)` artinya **"tidak ada parameter tambahan di namelist itu"**, bukan
error. Kalau `&SYSTEM` isinya cuma `ibrav`, `nat`, `ntyp`, `ecutwfc`,
`ecutrho`, `occupations`, `smearing`, `degauss` — semuanya sudah termasuk 16
yang dikenali, jadi tidak ada sisa untuk disalin.

**Kalau kamu memakai `vdw_corr`, `nspin`, atau `nbnd`, namanya WAJIB muncul di
baris `&SYSTEM passthrough`.** Kalau tidak muncul, parameter itu tidak akan
sampai ke tahap berikutnya.

**`cards carried over`** — card `HUBBARD` (DFT+U) dan `OCCUPATIONS` kalau ada.

## 6. Jalankan pipeline

### Laptop

```bash
bash qe.sh cases/mos2/mos2_relax.in
```

### Cluster

```bash
sbatch qe.sh cases/mos2/mos2_relax.in
squeue -u $USER
```

Beberapa material sekaligus dalam satu job:

```bash
sbatch qe.sh cases/mos2/mos2_relax.in cases/ws2/ws2_relax.in
```

Keduanya jalan bergantian, masing-masing mendapat seluruh alokasi. Satu case
yang gagal tidak menghentikan yang lain.

**Apa yang dikerjakan — 12 tahap berurutan:**

| # | Tahap | Isinya |
|---|---|---|
| 1 | `parser` | baca input, tulis `cache/parser.cache` |
| 2 | `relax` | `pw.x` — optimasi struktur |
| 3 | `extract` | ambil geometri hasil relaksasi dari output |
| 4 | `gen-scf` | tulis `mos2_scf.in` |
| 5 | `scf` | `pw.x` — hitung rapat muatan |
| 6 | `gen-band` | tulis `mos2_band.in` (pakai `mos2_band.path`) |
| 7 | `band` | `pw.x` — energi sepanjang rute |
| 8 | `bandsx` | `bands.x` — susun jadi `pwscf.bands.dat.gnu` |
| 9 | `gen-nscf` | tulis `mos2_nscf.in`, mesh k lebih rapat |
| 10 | `nscf` | `pw.x` — untuk DOS |
| 11 | `dos` | `dos.x` — hasilkan `pwscf.dos` |
| 12 | `plot` | gambar band, DOS, dan keduanya berdampingan |

**Yang muncul selama jalan:** tiap tahap mencetak header, waktu mulai, waktu
selesai, dan durasinya.

```
[5/12 SCF]
  started : 2026-07-30 10:41:52
Running pw.x : mos2_scf.in -> mos2_scf.out
SUCCESS : /home/arsy54/QE_workflow/cases/mos2/mos2_scf.out
  finished: 2026-07-30 10:42:03
  duration: 0h0m11s
```

Di tahap 12 akan muncul baris penting:

```
[12/12 PLOT]
  engine    : python
  E_Fermi   : -2.0755 eV  (nscf output - the densest mesh, and what dos.x used)
  window    : -5.0 .. 5.0 eV around E_Fermi
  path      : G M K G
wrote mos2_band.png
```

Baris `E_Fermi` menyebutkan **dari mana** angka nol diambil. Kalau tertulis
`scf output - COARSE MESH FALLBACK`, berarti tahap nscf tidak jalan dan nolnya
kurang bisa dipercaya.

Baris `path` harus cocok dengan label di `band.path`-mu.

**Selesai kalau muncul:**

```
=========================================
Workflow Finished Successfully
=========================================
```

## 7. Lihat hasilnya

```bash
ls cases/mos2/
```

```
mos2_band.png           gambar band structure
mos2_dos.png            gambar DOS
mos2_band_dos.png       keduanya berdampingan, satu sumbu energi
mos2_plot.py            skrip yang menggambar ketiganya

pwscf.bands.dat.gnu     data band mentah
pwscf.dos               data DOS mentah (baris pertama memuat E_Fermi)

mos2_relax.out          output tiap tahap
mos2_scf.out
mos2_band.out
mos2_nscf.out
```

Semua gambar diukur dari E_Fermi, jadi **0 pada sumbu tegak = E_Fermi**, ditandai
garis putus-putus merah.

## 8. Menyetel ulang gambar

```bash
cd cases/mos2
nano mos2_plot.py
python3 mos2_plot.py
```

Di bagian atas `mos2_plot.py` ada blok pengaturan:

```python
# ------------------------------- settings --------------------------------
E_FERMI    = -2.0755
EMIN, EMAX = -5.0, 5.0          # jendela energi, eV, relatif E_FERMI
TICKS      = [0.0, 0.5774, 1.0865, 1.4714]
LABELS     = ["G", "M", "K", "G"]
BAND_COLOR = "#1f4e79"
DPI        = 300
# -------------------------------------------------------------------------
```

Ubah seperlunya lalu jalankan sendiri. **Tidak ada perhitungan DFT yang
diulang** — skrip ini cuma membaca file data yang sudah jadi, hitungannya
beberapa detik.

Menjalankan `bash qe.sh plot ...` lagi akan **menimpa** file ini, jadi simpan
salinan dengan nama lain kalau sudah kamu setel.

Untuk menggambar ulang tanpa menghitung apa pun — misalnya setelah menyalin
folder case dari cluster ke laptop:

```bash
bash qe.sh plot cases/mos2/mos2_relax.in
```

## 9. Kalau ada yang gagal

```bash
bash qe.sh check cases/mos2/mos2_relax.in
```

Menampilkan tahap mana yang selesai dan mana yang gagal, beserta diagnosis
sebab dan solusinya untuk error QE yang pesannya tidak menjelaskan sebabnya
sendiri.

```
SUCCESS : mos2_relax.out
SUCCESS : mos2_scf.out
FAILED  : mos2_band.out

  DIAGNOSIS: 'wrong record length' from diropn means a rank ended up
  with zero plane waves ...
  FIX: raise NPOOL in config.sh, or lower NPROC.

3 output(s) checked, 1 failed.
```

**Kalau run terhenti di tengah** (batas waktu, `scancel`, Ctrl-C), bersihkan
dulu sebelum mengulang:

```bash
rm -rf cases/mos2/{work,cache,logs}
```

Ini **wajib**. Kalau tidak, run berikutnya akan memakai sisa `work/` yang
setengah jadi.

## 10. Menjalankan satu tahap saja

Untuk debugging, tiap tahap bisa dipanggil sendiri asal tahap sebelumnya sudah
pernah jalan:

```bash
bash qe.sh scf      cases/mos2/mos2_relax.in
bash qe.sh gen-nscf cases/mos2/mos2_relax.in
bash qe.sh plot     cases/mos2/mos2_relax.in
```

Daftar lengkap tahap:

```bash
bash qe.sh
```

---

# BAGIAN 3 — Disclaimer: Syarat Mutlak

## A. Syarat yang ditolak sistem (kamu akan dapat pesan error)

Kalau salah satu ini tidak dipenuhi, workflow berhenti di detik pertama dengan
pesan yang menyebut sebab dan solusinya. Tidak ada perhitungan yang terlanjur
jalan.

### 1. Nama file harus berakhiran `_relax.in`

```
BENAR  : mos2_relax.in     ws2_relax.in     si_relax.in
SALAH  : mos2.relax.in     mos2_relax.txt   relax_mos2.in
```

Garis bawah, bukan titik. Nama case diambil dari bagian sebelum `_relax.in`,
dan semua file turunan dinamai dari situ (`mos2_scf.in`, `mos2_band.out`, dst).

Ini juga yang membuat `bash qe.sh scf mos2_relax.in` tidak ambigu: nama tahap
tidak pernah berakhiran `_relax.in`, jadi sistem tahu mana tahap dan mana file.

### 2. `ibrav = 0`, dan harus ditulis eksplisit

```fortran
&SYSTEM
    ibrav = 0
/
```

`ibrav = 2`, `ibrav = 8`, atau `ibrav` yang tidak ditulis sama sekali — semua
ditolak.

**Alasannya:** geometri dioper antar tahap sebagai card `CELL_PARAMETERS`.
Input dengan `ibrav ≠ 0` mendeskripsikan kisinya lewat `celldm`/`A`/`B`/`C`,
jadi tidak ada `CELL_PARAMETERS` untuk diambil.

**Kalau inputmu dari tutorial atau paper** yang biasanya memakai `ibrav ≠ 0`,
konversikan dulu: hitung tiga vektor kisi dari `celldm`, tulis sebagai card
`CELL_PARAMETERS`, lalu set `ibrav = 0`.

### 3. Harus ada card `CELL_PARAMETERS`

```fortran
CELL_PARAMETERS {angstrom}
3.190000000 0.000000000 0.000000000
1.595000000 2.762620000 0.000000000
0.000000000 0.000000000 20.000000000
```

Konsekuensi dari nomor 2. Juga dipakai `init` untuk mengukur kisi.

### 4. `K_POINTS` harus `automatic` atau `gamma`

```fortran
K_POINTS {automatic}
12 12 1 0 0 0
```

atau, untuk molekul terisolasi:

```fortran
K_POINTS {gamma}
```

**Ditolak:** `K_POINTS crystal`, `K_POINTS tpiba`, dan bentuk daftar titik
eksplisit lainnya.

**Alasannya:** tahap nscf perlu **memperbesar** mesh ini (dikali
`NSCF_KPOINT_SCALE`) untuk mendapat DOS yang halus. Daftar titik eksplisit
tidak punya mesh untuk diperbesar.

Tahap band tidak terpengaruh — rutenya selalu diambil dari `<case>_band.path`,
bukan dari sini.

**Khusus `gamma`:** wajib `NPOOL_WANTED=1` di `config.sh`. Satu titik k tidak
bisa dibagi ke beberapa pool.

### 5. Parameter yang wajib ada

| Parameter | Namelist |
|---|---|
| `ibrav` | `&SYSTEM` |
| `nat` | `&SYSTEM` |
| `ntyp` | `&SYSTEM` |
| `ecutwfc` | `&SYSTEM` |
| `pseudo_dir` | `&CONTROL` |

Ditambah card `ATOMIC_SPECIES` yang berisi nama file `.UPF`.

### 6. File pseudopotensial harus benar-benar ada

Nama di `ATOMIC_SPECIES` harus cocok dengan file yang ada di `pseudo_dir`.
Periksa dengan `ls` sebelum menjalankan.

---

## B. Syarat yang TIDAK ditolak sistem — tanggung jawabmu sendiri

**Ini bagian yang paling berbahaya.** Sistem tidak memeriksanya, tidak ada
error, tapi hasilnya salah.

### 1. `calculation` harus `'relax'` atau `'vc-relax'`

```fortran
&CONTROL
    calculation = 'relax'
/
```

**Tidak diperiksa sistem.** Kalau kamu tulis `'scf'`, workflow tetap jalan,
tapi tahap `extract` tidak menemukan blok `Begin final coordinates` dan
diam-diam memakai posisi dari input. Untuk `vc-*` ada peringatan; untuk `scf`
tidak ada.

Pakai `relax` kalau ingin selnya tetap (mengikuti struktur acuan), `vc-relax`
kalau selnya juga ingin dioptimasi.

### 2. Satu material = satu folder

Hasil akhir selalu bernama `pwscf.dos` dan `pwscf.bands.dat.gnu`. Dua material
dalam satu folder akan saling menimpa, **tanpa peringatan**.

### 3. `occupations` harus cocok dengan jenis materialnya

| Material | Yang benar |
|---|---|
| Logam, semimetal (graphene) | `occupations = 'smearing'` + `smearing` + `degauss` |
| Semikonduktor, insulator | `'smearing'` (aman) atau `'fixed'` |

Kalau `occupations` tidak ditulis, QE memakai `'fixed'`. Untuk graphene itu
**salah** — pita valensi dan konduksi bersentuhan di titik Dirac, tidak ada
gap. Parser mencetak `note:` kalau ini terjadi, jadi baca keluaran `dump`.

### 4. Konvergensi fisika tetap tanggung jawabmu

Workflow **tidak memeriksa**:

- ketebalan vakum cukup atau tidak untuk slab
- `ecutwfc` sudah konvergen atau belum
- kerapatan mesh k cukup atau belum
- rasio `ecutrho/ecutwfc` (untuk pseudo ultrasoft minimal 8, PAW sekitar 8–12)

Angka yang terlalu kecil akan menghasilkan perhitungan yang selesai dengan
sukses tapi hasilnya tidak bermakna.

### 5. `nbnd` tidak dinaikkan otomatis

Kalau inputmu tidak menulis `nbnd`, QE memakai defaultnya — kira-kira
1.2 × jumlah elektron/2. Untuk band structure itu sering hanya menyisakan
sedikit pita konduksi, sehingga bagian atas grafik kosong.

Solusinya: tulis `nbnd` di `&SYSTEM` file relax-mu. Nilainya akan lewat
passthrough dan sampai ke tahap band. Pastikan namanya muncul di baris
`&SYSTEM passthrough` saat `dump`.

### 6. Rute band adalah pilihanmu, bukan kebenaran mutlak

`init` menulis rute **standar** untuk kisi tersebut. Itu belum tentu rute yang
dipakai paper pembandingmu. Kalau ingin dibandingkan berdampingan, samakan
rutenya secara manual.

### 7. Untuk material bergap, jangan pakai E_Fermi sebagai acuan gambar

Dengan smearing, E_Fermi ditempatkan di mana pun integral okupasi jatuh —
biasanya dekat tepi pita, bukan di tengah gap. Untuk gambar publikasi, acuan
yang benar adalah **VBM** (puncak pita valensi).

Caranya: cari VBM dari data pita, lalu set `E_FERMI` ke nilai itu di
`<case>_plot.py` dan jalankan ulang skripnya.

### 8. Jangan membaca lebar gap dari gambar DOS

`dos.x` mewarisi pelebaran (smearing) dari tahap nscf. Untuk material bergap,
pelebaran itu mengaburkan tepi gap sehingga gap terbaca lebih sempit dari
seharusnya — dan dengan smearing Methfessel-Paxton, DOS di dalam gap bahkan
bisa sedikit negatif.

Baca lebar gap dari **data pita** (`pwscf.bands.dat.gnu`), bukan dari grafik
DOS.

---

## C. Catatan mesin

| | Laptop | Cluster |
|---|---|---|
| Menjalankan | `bash qe.sh ...` | `sbatch qe.sh ...` |
| Jumlah proses | jumlah core fisik, dideteksi otomatis | dari alokasi SLURM |
| `pw.x` | dari `PATH` | dari module |
| Gambar | matplotlib | **tidak ada** — lihat catatan di bawah |

File `qe.sh`, `config.sh`, dan seluruh `lib/` **identik** di laptop dan
cluster. Keduanya mendeteksi mesinnya sendiri, bukan dikonfigurasi terpisah.
Perbedaan di antara keduanya adalah bug, bukan setelan. Periksa dengan
`md5sum qe.sh config.sh lib/*.sh` di kedua sisi.

**Di cluster tidak ada matplotlib maupun gnuplot di PATH**, jadi tahap `plot`
akan melewati dirinya sendiri dengan pesan penjelasan — perhitungan **tetap
dinyatakan berhasil**, hanya gambarnya yang tidak dibuat. Salin folder case ke
laptop lalu jalankan `bash qe.sh plot ...` di sana:

```bash
scp -r mahameru:_scratch/arsy/QE_workflow_v2/cases/mos2 ~/QE_workflow/cases/
cd ~/QE_workflow
bash qe.sh plot cases/mos2/mos2_relax.in
```

---

Detail teknis, riwayat bug yang sudah diperbaiki, dan keterbatasan yang masih
terbuka ada di `MAINTENANCE.md` — dokumen itu untuk siapa pun yang akan
**mengedit** `qe.sh`. `README.md` menjelaskan apa yang workflow ini lakukan dan
kenapa dibangun seperti ini.
