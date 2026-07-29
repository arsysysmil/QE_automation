# Quantum ESPRESSO Automation Workflow

Dari satu file input relax, workflow ini menjalankan seluruh rantai
perhitungan sampai dapat **band structure** dan **DOS**.

---

## 1. Buka folder workflow

```bash
cd ~/QE_workflow
```

---

## 2. Buat folder case/material baru

Contoh untuk MoS2

```bash
mkdir -p cases/mos2
```

> **Satu material = satu folder.** Hasil akhir selalu bernama `pwscf.dos` dan
> `pwscf.bands.dat.gnu`, jadi dua material dalam satu folder akan saling
> menimpa hasilnya.

---

## 3. Masukkan file RELAX

Simpan file input QE ke dalam folder tersebut.

Nama file HARUS:

```text
mos2_relax.in
```

Garis bawah, bukan titik. `mos2.relax.in` akan ditolak.

Struktur folder:

```text
cases/
└── mos2/
    └── mos2_relax.in
```

Syarat isi file:

| Harus ada | Keterangan |
|---|---|
| `calculation = 'relax'` atau `'vc-relax'` | workflow mulai dari tahap relax |
| `ibrav = 0` + card `CELL_PARAMETERS` | geometri dioper antar tahap lewat card ini |
| `K_POINTS automatic` + baris mesh | atau `K_POINTS gamma` untuk molekul |
| `pseudo_dir` benar | file `.upf` di `ATOMIC_SPECIES` harus ada di sana |

Parameter lain — `vdw_corr`, `nspin`, `nbnd`, card `HUBBARD` — cukup ditulis
sekali di file ini. Semuanya terbawa otomatis ke tahap berikutnya.

---

## 4. Buat file Band Path

```bash
bash qe.sh init cases/mos2/mos2_relax.in
```

Perintah ini mengukur kisi dari `CELL_PARAMETERS` di input kamu, lalu menulis
`mos2_band.path` dengan jalur simetri yang sesuai. Keluarannya:

```text
Lattice measured from mos2_relax.in:
  a = 3.1900   b = 3.1900   c = 20.0000
  alpha = 90.00   beta = 90.00   gamma = 60.00
  -> hexagonal slab, gamma=60 setting  (2D: path stays at k_z = 0)

Band path written: cases/mos2/mos2_band.path
```

Sekarang folder menjadi

```text
cases/
└── mos2/
    ├── mos2_relax.in
    └── mos2_band.path
```

**Baca baris `->` itu.** Kalau klasifikasinya bukan yang kamu maksud, jangan
diteruskan. Kalau kisimu tidak dikenali, `init` menolak menebak dan menyuruh
kamu menulis sendiri — itu disengaja, karena jalur yang salah menghasilkan
band structure yang terlihat wajar tanpa error apa pun.

Kisi yang dikenali: heksagonal (setting γ=60 dan γ=120, 2D maupun 3D), kubik
sederhana, FCC, BCC, tetragonal, ortorombik.

> **Kenapa tidak menyalin template saja?** Karena titik K berbeda antara
> setting γ=60° dan γ=120°: (2/3,1/3,0) versus (1/3,1/3,0). Keduanya
> heksagonal, tapi menyalin yang salah menaruh label "K" pada titik di dalam
> zona Brillouin — untuk graphene, titik Dirac-nya hilang sama sekali dan
> tidak ada pesan error. `init` membedakannya dari sudut yang diukur.
>
> Template masih ada di `template/` kalau kamu perlu menulis jalur sendiri,
> dengan nama yang menyebut setting-nya: `band.path.hex_gamma60_example` dan
> `band.path.hex_gamma120_example`.

---

## 5. Cek input (Opsional, disarankan)

```bash
bash qe.sh dump cases/mos2/mos2_relax.in
```

Pastikan parameter seperti NAT, ECUTWFC, K_POINTS sudah benar.

Perhatikan juga dua baris ini:

- `passthrough &SYSTEM:` — kalau kamu memakai `vdw_corr` atau `nspin`,
  namanya harus muncul di sini
- `note: ... using default ...` — ada parameter yang tidak kamu tulis dan
  diisi otomatis

Gratis, tanpa MPI, beberapa detik. Semua kesalahan di langkah 3 ketahuan di
sini, bukan setelah perhitungan berjalan berjam-jam.

---

## 6. Jalankan Workflow

### Laptop

```bash
bash qe.sh cases/mos2/mos2_relax.in
```

### Cluster (SLURM)

```bash
sbatch qe.sh cases/mos2/mos2_relax.in
```

Workflow akan otomatis menjalankan:

```
Relax
   ↓
SCF
   ↓
Band  →  bands.x
   ↓
NSCF
   ↓
DOS
   ↓
Plot
```

Beberapa material sekaligus dalam satu job:

```bash
sbatch qe.sh cases/mos2/mos2_relax.in cases/ws2/ws2_relax.in
```

---

## 7. Cek Hasil

Hasil berada pada folder case:

```text
cases/mos2/

pwscf.bands.dat.gnu     data band structure
pwscf.dos               data DOS (baris pertama memuat E_Fermi)

mos2_band.png           gambar band structure
mos2_dos.png            gambar DOS
mos2_band_dos.png       keduanya berdampingan, satu sumbu energi
mos2_plot.py            script yang menggambar ketiganya
```

Log ditutup dengan `Workflow Finished Successfully`.

Semua gambar diukur dari E_Fermi, jadi angka 0 pada sumbu tegak berarti tepat
di E_Fermi (garis putus-putus merah).

> **Jangan membandingkan E_Fermi absolut antar mesin atau antar versi QE** —
> untuk sistem bergap nilai itu tidak tertentukan secara unik. Selaraskan pada
> tepi pita.

---

## 8. Mengubah Tampilan Gambar

Gambar digambar oleh `mos2_plot.py` yang ada di folder case itu sendiri. Buka
file tersebut; di bagian atas ada blok pengaturan:

```python
# ------------------------------- settings --------------------------------
E_FERMI    = 2.1391
EMIN, EMAX = -5.0, 5.0          # jendela energi, eV, relatif E_Fermi
TICKS      = [0.0, 0.5774, 1.0865, 1.4714]
LABELS     = ["G", "M", "K", "G"]
BAND_COLOR = "#1f4e79"
DPI        = 300
# -------------------------------------------------------------------------
```

Ubah seperlunya lalu jalankan sendiri, tanpa lewat `qe.sh`:

```bash
cd cases/mos2
python3 mos2_plot.py
```

Untuk menggambar ulang tanpa menjalankan perhitungan apa pun (misalnya setelah
menyalin folder case dari cluster ke laptop):

```bash
bash qe.sh plot cases/mos2/mos2_relax.in
```

Perintah ini menulis ulang `mos2_plot.py`, jadi simpan salinan dengan nama lain
kalau kamu sudah menyetelnya.

Pilihan mesin gambar ada di `config.sh`:

```bash
PLOT_ENGINE="auto"    # auto | python | gnuplot | none
PLOT_EMIN=-5.0
PLOT_EMAX=5.0
```

`auto` memakai matplotlib kalau ada, kalau tidak gnuplot. Node cluster sering
punya gnuplot tapi tidak punya matplotlib, dan sebaliknya di laptop — hasil
keduanya sama.

Kalau tidak ada satu pun, perhitungan **tetap dinyatakan berhasil**; hanya
gambarnya yang tidak dibuat. Data mentahnya sudah ada, tinggal digambar di
mesin lain.

---

## 9. Jika Terjadi Error

```bash
bash qe.sh check cases/mos2/mos2_relax.in
```

Perintah ini akan menampilkan tahap mana yang gagal beserta penyebab dan
solusi yang memungkinkan.

Kalau run terhenti di tengah (batas waktu, `scancel`), bersihkan dulu sebelum
mengulang:

```bash
rm -rf cases/mos2/{work,cache,logs}
```

---

## Menjalankan satu tahap saja

Untuk debugging, tiap tahap bisa dipanggil sendiri:

```bash
bash qe.sh scf      cases/mos2/mos2_relax.in
bash qe.sh gen-nscf cases/mos2/mos2_relax.in
```

Daftar lengkap tahap:

```bash
bash qe.sh
```

---

## Yang perlu diketahui

- **Material yang didukung:** slab 2D, bulk 3D sembarang kisi, insulator,
  logam, sistem magnetik (`nspin=2`), DFT+U, multi-spesies, molekul terisolasi
  (`K_POINTS gamma`, butuh `NPOOL_WANTED=1` di `config.sh`).
- **Yang ditolak:** `ibrav ≠ 0` dan daftar k-point eksplisit
  (`K_POINTS crystal`/`tpiba`). Keduanya ditolak di langkah pertama dengan
  pesan yang menyebut sebab dan solusinya.
- **Konvergensi fisika tetap tanggung jawabmu.** Workflow tidak memeriksa
  ketebalan vakum, cutoff, atau kerapatan mesh.
- **Laptop vs cluster:** file dan langkahnya identik, hanya `bash` vs
  `sbatch`. `config.sh` mendeteksi sendiri jumlah core dan ada/tidaknya
  module.

Detail teknis dan riwayat perbaikan ada di `MAINTENANCE.md`, yang ditujukan
untuk siapa pun yang akan mengedit `qe.sh`.
