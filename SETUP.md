# QE_automation — Panduan Penggunaan

## Apa ini

QE_automation menjalankan rantai perhitungan Quantum ESPRESSO secara otomatis.
Dari **satu file input relax**, sistem ini mengerjakan seluruh tahapan sampai
selesai:

```
relax → scf → band → bands.x → nscf → dos → plot
```

Hasil akhirnya: **band structure**, **DOS**, dan gambarnya dalam format PNG.

Tanpa sistem ini, ketujuh tahap tersebut dijalankan manual satu per satu, dan
setiap tahap memerlukan file input baru yang ditulis tangan dari hasil tahap
sebelumnya.

Sistem berjalan di laptop maupun di cluster SLURM dengan perintah yang sama.

---

# 1. Syarat Wajib

**Baca bagian ini sebelum menjalankan apa pun.** Input yang tidak memenuhi
syarat akan ditolak, atau lebih buruk lagi, tetap berjalan tetapi hasilnya
keliru.

## 1.1 Syarat yang diperiksa sistem

Bila salah satu tidak dipenuhi, sistem berhenti seketika dengan pesan yang
menyebut penyebab dan solusinya. Tidak ada perhitungan yang terlanjur berjalan.

### Nama file harus berakhiran `_relax.in`

```
BENAR  : mos2_relax.in     si_relax.in
SALAH  : mos2.relax.in     mos2_relax.txt
```

Garis bawah, bukan titik. Nama material diambil dari bagian sebelum
`_relax.in`, dan semua file turunan dinamai dari situ.

### `ibrav = 0`, ditulis eksplisit

```fortran
&SYSTEM
    ibrav = 0
/
```

Geometri dioper antar tahap sebagai card `CELL_PARAMETERS`. Input dengan
`ibrav ≠ 0` mendeskripsikan kisi melalui `celldm`, sehingga tidak ada
`CELL_PARAMETERS` untuk diambil.

> Input dari tutorial atau paper umumnya memakai `ibrav ≠ 0`. Konversikan lebih
> dulu: hitung tiga vektor kisi dari `celldm`, tulis sebagai card
> `CELL_PARAMETERS`, lalu set `ibrav = 0`.

### Harus ada card `CELL_PARAMETERS`

```fortran
CELL_PARAMETERS {angstrom}
3.190000000 0.000000000 0.000000000
1.595000000 2.762620000 0.000000000
0.000000000 0.000000000 20.000000000
```

### `K_POINTS` harus `automatic` atau `gamma`

```fortran
K_POINTS {automatic}
12 12 1 0 0 0
```

`K_POINTS crystal`, `tpiba`, dan daftar titik eksplisit **ditolak**. Tahap nscf
perlu memperbesar mesh ini untuk memperoleh DOS yang halus, sedangkan daftar
titik eksplisit tidak memiliki mesh untuk diperbesar.

Untuk molekul terisolasi gunakan `K_POINTS {gamma}`, disertai `NPOOL_WANTED=1`
di `config.sh`.

### Parameter yang wajib ada

| Parameter | Namelist |
|---|---|
| `ibrav`, `nat`, `ntyp`, `ecutwfc` | `&SYSTEM` |
| `pseudo_dir` | `&CONTROL` |

Ditambah card `ATOMIC_SPECIES`. File `.UPF` yang disebut di dalamnya harus
benar-benar tersedia di `pseudo_dir`.

## 1.2 Syarat yang TIDAK diperiksa sistem

**Bagian ini yang paling sering menimbulkan masalah.** Tidak ada pesan error,
perhitungan selesai dengan sukses, tetapi hasilnya keliru.

### `calculation` harus `'relax'` atau `'vc-relax'`

```fortran
&CONTROL
    calculation = 'relax'
/
```

Bila ditulis `'scf'`, sistem tetap berjalan tetapi struktur hasil relaksasi
tidak ditemukan, dan posisi atom diambil dari input tanpa pemberitahuan.

Gunakan `relax` bila bentuk sel ingin dipertahankan, `vc-relax` bila sel juga
ingin dioptimasi.

### Satu material = satu folder

File hasil akhir selalu bernama `pwscf.dos` dan `pwscf.bands.dat.gnu`. Dua
material dalam satu folder akan saling menimpa hasilnya tanpa peringatan.

### `occupations` harus sesuai jenis material

| Material | Pengaturan |
|---|---|
| Logam, semimetal (misalnya graphene) | `occupations = 'smearing'` + `smearing` + `degauss` |
| Semikonduktor, insulator | `'smearing'` atau `'fixed'` |

Bila `occupations` tidak ditulis, QE memakai `'fixed'`. Untuk graphene itu
keliru, karena pita valensi dan konduksi bersentuhan di titik Dirac.

### Konvergensi fisika bukan tanggung jawab sistem

Sistem tidak memeriksa ketebalan vakum, kecukupan `ecutwfc`, kerapatan mesh k,
maupun rasio `ecutrho/ecutwfc`. Nilai yang terlalu kecil menghasilkan
perhitungan yang selesai dengan sukses namun tidak bermakna.

### `nbnd` tidak dinaikkan otomatis

Bila `nbnd` tidak ditulis, QE memakai nilai bawaan yang menyisakan sedikit pita
konduksi, sehingga bagian atas grafik band menjadi kosong. Tulis `nbnd` di
`&SYSTEM` bila diperlukan.

---

# 2. Urutan Perintah

Contoh untuk material bernama `mos2`.

### Laptop

```bash
cd ~/QE_automation
mkdir -p cases/mos2
cp /lokasi/file/mos2_relax.in cases/mos2/
bash qe.sh init cases/mos2/mos2_relax.in
bash qe.sh dump cases/mos2/mos2_relax.in
bash qe.sh      cases/mos2/mos2_relax.in
```

### Cluster (SLURM)

```bash
cd _scratch/arsy/QE_automation
mkdir -p cases/mos2
cp /lokasi/file/mos2_relax.in cases/mos2/
bash   qe.sh init cases/mos2/mos2_relax.in
bash   qe.sh dump cases/mos2/mos2_relax.in
sbatch qe.sh      cases/mos2/mos2_relax.in
squeue -u $USER
```

Perbedaannya hanya pada baris terakhir: `bash` di laptop, `sbatch` di cluster.

---

# 3. Penjelasan Tiap Perintah

## `mkdir -p cases/mos2`

Membuat folder khusus untuk satu material. Seluruh file — input, output, data,
gambar — akan berada di dalamnya.

## `cp ... cases/mos2/`

Menempatkan file input relax ke dalam folder tersebut.

## `bash qe.sh init ...`

**Membuat jalur band.**

Sistem mengukur panjang rusuk dan sudut sel dari `CELL_PARAMETERS`,
menyimpulkan jenis kisinya, lalu menulis `mos2_band.path` berisi rute titik
simetri yang sesuai.

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

**Periksa baris `->`.** Pastikan jenis kisi yang disimpulkan sesuai dengan
material yang dimaksud. Bila tertulis "tetragonal" padahal materialnya
heksagonal, berarti ada yang keliru pada `CELL_PARAMETERS`.

Jalur yang salah **tidak menghasilkan error** — grafiknya tetap keluar dan
tampak wajar, tetapi isinya bukan yang dimaksud. Karena itu langkah ini
dipisahkan, agar hasilnya dapat diperiksa lebih dulu.

Bila jenis kisi tidak dikenali, sistem menolak menebak dan meminta jalur
ditulis manual. File `.path` yang sudah ada tidak pernah ditimpa, sehingga
jalur tulisan tangan selalu diutamakan.

## `bash qe.sh dump ...`

**Memeriksa pembacaan input.** Gratis, beberapa detik, tanpa perhitungan.

Menampilkan parameter yang terbaca sistem. Cocokkan `NAT`, `NTYP`, `ECUTWFC`,
`K_POINTS`, dan nama file pseudopotensial dengan yang dimaksud.

Dua hal yang perlu diperhatikan pada keluarannya:

**Baris `note: ... using default ...`** — ada parameter yang tidak ditulis di
input dan diisi otomatis. Pastikan nilai bawaannya memang sesuai.

**Baris `passthrough`** — sistem mengenali 16 parameter utama; parameter di
luar itu disalin apa adanya ke tahap berikutnya. Bila menggunakan `vdw_corr`,
`nspin`, atau `nbnd`, namanya **harus** muncul di baris `&SYSTEM passthrough`.
Tulisan `(none)` berarti tidak ada parameter tambahan, bukan error.

## `bash qe.sh ...` / `sbatch qe.sh ...`

**Menjalankan seluruh pipeline**, 12 tahap berurutan:

| # | Tahap | Isinya |
|---|---|---|
| 1 | `parser` | membaca input |
| 2 | `relax` | optimasi struktur |
| 3 | `extract` | mengambil geometri hasil relaksasi |
| 4–5 | `gen-scf`, `scf` | menghitung rapat muatan |
| 6–8 | `gen-band`, `band`, `bandsx` | energi sepanjang jalur band |
| 9–10 | `gen-nscf`, `nscf` | mesh k lebih rapat untuk DOS |
| 11 | `dos` | menghasilkan data DOS |
| 12 | `plot` | menggambar band dan DOS |

Setiap tahap mencetak waktu mulai, selesai, dan durasinya. Proses selesai bila
muncul:

```
Workflow Finished Successfully
```

Beberapa material sekaligus dalam satu job:

```bash
sbatch qe.sh cases/mos2/mos2_relax.in cases/ws2/ws2_relax.in
```

Keduanya berjalan bergantian. Satu material yang gagal tidak menghentikan yang
lain.

---

# 4. Hasil

Seluruhnya berada di dalam folder material:

```
cases/mos2/
├── mos2_band.png          gambar band structure
├── mos2_dos.png           gambar DOS
├── mos2_band_dos.png      keduanya berdampingan, satu sumbu energi
├── mos2_plot.py           skrip yang menggambar ketiganya
├── pwscf.bands.dat.gnu    data band
└── pwscf.dos              data DOS
```

Pada semua gambar, **angka 0 pada sumbu tegak menandai E_Fermi**, ditampilkan
sebagai garis putus-putus merah.

## Menyetel ulang gambar

```bash
cd cases/mos2
nano mos2_plot.py
python3 mos2_plot.py
```

Bagian atas skrip berisi blok pengaturan yang dapat diubah bebas:

```python
E_FERMI    = -2.0755
EMIN, EMAX = -5.0, 5.0      # jendela energi, eV, relatif E_FERMI
LABELS     = ["G", "M", "K", "G"]
DPI        = 300
```

Menjalankan ulang skrip ini **tidak mengulang perhitungan DFT** — hanya membaca
data yang sudah jadi, selesai dalam hitungan detik.

> Untuk material bergap, sebaiknya `E_FERMI` diisi nilai **VBM** (puncak pita
> valensi), bukan E_Fermi. Dengan smearing, E_Fermi ditempatkan di dekat tepi
> pita, bukan di tengah gap.
>
> Lebar gap juga sebaiknya dibaca dari data pita, bukan dari grafik DOS —
> pelebaran pada DOS membuat gap terbaca lebih sempit dari seharusnya.

---

# 5. Bila Terjadi Kegagalan

```bash
bash qe.sh check cases/mos2/mos2_relax.in
```

Menampilkan tahap mana yang berhasil dan mana yang gagal, disertai diagnosis
penyebab beserta solusinya.

Bila proses terhenti di tengah jalan (batas waktu, `scancel`, Ctrl-C),
**bersihkan lebih dulu** sebelum mengulang:

```bash
rm -rf cases/mos2/{work,cache,logs}
```

Tanpa ini, proses berikutnya akan memakai sisa perhitungan yang belum selesai.

## Menjalankan satu tahap saja

```bash
bash qe.sh scf  cases/mos2/mos2_relax.in
bash qe.sh plot cases/mos2/mos2_relax.in
```

Daftar lengkap tahap yang tersedia:

```bash
bash qe.sh
```

---

# 6. Catatan Mesin

| | Laptop | Cluster |
|---|---|---|
| Menjalankan | `bash qe.sh` | `sbatch qe.sh` |
| Jumlah proses | core fisik, terdeteksi otomatis | dari alokasi SLURM |
| `pw.x` | dari `PATH` | dari module |

File `qe.sh`, `config.sh`, dan seluruh `lib/` **identik** di kedua mesin.
Keduanya mendeteksi lingkungannya sendiri, bukan dikonfigurasi terpisah.

Bila cluster tidak memiliki matplotlib maupun gnuplot, tahap `plot` akan
dilewati disertai pesan penjelasan — **perhitungan tetap dinyatakan berhasil**,
hanya gambarnya yang tidak dibuat. Salin folder material ke laptop, lalu gambar
di sana:

```bash
scp -r <cluster>:_scratch/arsy/QE_automation/cases/mos2 ~/QE_automation/cases/
cd ~/QE_automation
bash qe.sh plot cases/mos2/mos2_relax.in
```

---

Dokumen lain: `README.md` menjelaskan cara kerja dan alasan rancangannya;
`MAINTENANCE.md` ditujukan bagi siapa pun yang akan mengubah kodenya.
