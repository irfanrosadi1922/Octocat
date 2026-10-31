# Ordela
Aplikasi POS Ordela

## Pendaftaran, reset sandi, dan multi-toko (mode Supabase)

1. Unduh cadangan JSON lebih dulu (Pengaturan → Cadangan), lalu jalankan ulang `setup.sql` di Supabase → SQL Editor.
   Data lama otomatis menjadi toko nomor 1 dengan owner yang sama. Skrip aman diulang.
2. Supabase → Authentication → URL Configuration: isi **Site URL** dan **Redirect URLs** dengan alamat aplikasi (`https://app.ordela.my.id/`; alamat lama `https://USERNAME.github.io/ordela/` boleh tetap ditambahkan di Redirect URLs selama masa peralihan).
3. Authentication → Sign In / Providers → Email: biarkan **Confirm email** menyala (verifikasi boleh nanti, login tidak diblokir), set panjang sandi minimal 8.
4. Authentication → Emails: sesuaikan template *Confirm signup* dan *Reset password*; pasang SMTP sendiri untuk pengiriman nyata (SMTP bawaan sangat terbatas).
5. Opsional: aktifkan CAPTCHA di Authentication → Attack Protection (pengaturan dashboard, tanpa kode).

## Jabatan karyawan & izin Absensi

Di menu **Pengguna**, owner memilih **jabatan** karyawan dari daftar (Kasir, Pelayan, Koki, Barista, Manajer, Admin Gudang, dll.) atau menambah
jabatan sendiri lewat **Kelola Jabatan** (maks. 32 karakter). Jabatan buatan sendiri tersimpan per toko, muncul di pilihan berikutnya, dan bisa
dihapus dari daftar oleh owner (jabatan bawaan tidak bisa dihapus; karyawan lama tetap memakai jabatannya). Memilih jabatan mengisi izin awal
otomatis, dan izin tetap bisa diubah per karyawan.

Izin **Absensi** diatur per karyawan (default mati): bila mati, menu Absensi disembunyikan dan `/api/att` menjawab 403.
Setelah memperbarui kode, jalankan ulang `setup.sql` di Supabase SQL Editor.

### Kelola Jabatan

Di halaman **Pengguna**, tombol **Jabatan** membuka panel untuk menambah jabatan baru, mengubah namanya (karyawan yang memakainya ikut diperbarui),
menghapusnya dari daftar, dan mengatur izin awal tiap jabatan, termasuk Absensi. Pengaturan ini berlaku per toko dan hanya bisa diubah owner.

Semua jabatan kecuali Owner dan Staf bisa dihapus dari daftar supaya tidak terlalu banyak. Jabatan bawaan yang dihapus hanya disembunyikan: muncul di blok "Jabatan yang disembunyikan" di bawah panel dan bisa dipulihkan satu per satu atau sekaligus, dengan izin awal yang sama. Karyawan yang sudah memakai jabatan itu tidak berubah. Tidak ada perubahan skema, jadi `setup.sql` tidak perlu dijalankan ulang.

## Pergantian akun di satu perangkat

Data lokal aplikasi (menu, pesanan, pengaturan, cadangan) dicatat milik satu toko. Bila akun dari toko lain login di perangkat yang sama, data toko sebelumnya dibuang sebelum sinkron pertama sehingga tidak tertulis ke toko baru. Login ulang ke toko yang sama tidak menghapus apa pun. Perubahan yang belum tersinkron dari toko sebelumnya hilang saat pergantian; aplikasi sudah memperingatkannya saat keluar.

## Akun yang hanya punya izin Absensi

Karyawan yang izinnya **hanya Absensi** tidak bisa bertransaksi: menu Kasir, Meja, Beranda, dan Notifikasi disembunyikan, bottom nav tidak tampil, aplikasi langsung membuka halaman Absensi, dan server menolak (403) setiap perubahan pesanan atau stok dari akun itu. Karyawan dengan izin lain (atau tanpa izin tambahan) tetap memakai Kasir seperti biasa. Setelah memperbarui kode, jalankan ulang `setup.sql` di Supabase SQL Editor agar penolakan di server aktif.


## Domain sendiri: app.ordela.my.id
- File `CNAME` berisi `app.ordela.my.id`, jadi GitHub Pages melayani aplikasi di `https://app.ordela.my.id/`. Alamat QR pelanggan menjadi `https://app.ordela.my.id/order.html?s=KODETOKO`. Domain utama `ordela.my.id` dipakai untuk situs/landing page dan pengirim email.
- DNS (di penyedia domain): buat satu record `CNAME` dengan nama `app` yang menunjuk ke `irfanrosadi1922.github.io`. Domain utama `ordela.my.id` tidak perlu diarahkan ke GitHub Pages.
- GitHub → Settings → Pages → *Custom domain*: isi `app.ordela.my.id`, tunggu pemeriksaan DNS selesai, lalu centang **Enforce HTTPS**.
- Supabase → Authentication → URL Configuration: ubah **Site URL** menjadi `https://app.ordela.my.id/` dan tambahkan `https://app.ordela.my.id/**` ke Redirect URLs (tautan reset sandi dan verifikasi email memakai alamat ini). Alamat lama `https://ordela.my.id/**` boleh tetap ada sementara agar tautan email lama masih bisa dibuka. Kode aplikasi (`auth.js`) otomatis mengarahkan tautan email ke `app.ordela.my.id` walau pengguna membuka dari `ordela.my.id`.
- Template email Supabase (Authentication → Emails) harus memakai `{{ .ConfirmationURL }}` untuk tombol/tautan, jangan menulis alamat situs secara manual.
- Resend: domain pengirim tetap `ordela.my.id` (sudah terverifikasi); subdomain `app` tidak perlu ditambahkan ke Resend. Biarkan *click tracking* mati supaya tautan di email tidak dibungkus alamat lain.
- Bila memakai build APK, ubah variabel `APP_URL` di GitHub (Settings → Secrets and variables → Actions → Variables) menjadi `https://app.ordela.my.id/` atau kosongkan agar memakai isi `CNAME`.
- Build APK otomatis memakai isi `CNAME` sebagai alamat QR, kecuali variabel `APP_URL` diisi.

## Pembayaran online: QRIS dinamis
- Pengaturan → **Pembayaran Online**: tempel kode QRIS **statis** toko (teks berawalan `000201`, bisa dibaca dari foto di Chrome Android). Aplikasi memeriksa format dan CRC-nya, lalu menyimpannya.
- Saat pelanggan memilih **Bayar online**, aplikasi membuat QRIS **dinamis** di perangkat pelanggan: salinan QRIS toko dengan nominal pesanan sudah terisi (EMVCo tag 54, CRC dihitung ulang). Pelanggan tinggal memindai dan membayar tanpa mengetik angka.
- Tombol **Uji QR dinamis** menampilkan QR senilai Rp 1.000 untuk dipindai owner sendiri. Kalau aplikasi bank tidak mengisi nominal otomatis, QRIS statis toko tidak mendukungnya.
- Pembayaran tetap dikonfirmasi kasir lewat bukti bayar atau mutasi ("Pembayaran diterima"). Konfirmasi otomatis hanya mungkin lewat payment gateway (belum ada).
- Pesanan lama bertanda `duitnow` tetap dikenali dan ditampilkan sebagai QRIS. Setelah mengubah `setup.sql`, jalankan ulang di Supabase SQL Editor.

## Beranda: rekap penjualan + riwayat transaksi
- Menu **Laporan** dan **Riwayat Penjualan** dihapus; isinya menyatu di **Beranda** (tautan lama otomatis diarahkan ke Beranda).
- Satu filter periode (Hari ini, Kemarin, 7 Hari, Bulan ini, Semua, atau tanggal Dari-Sampai) mengatur seluruh Beranda: kartu ringkasan (dengan panah naik/turun dibanding periode sebelumnya), grafik, kategori, **Rekap Penjualan** (kotor, diskon, bersih, pajak, total diterima, transaksi, item terjual, rata-rata, estimasi laba, per metode bayar), menu terlaris, dan **Riwayat Transaksi** (ketuk untuk detail/struk, owner bisa hapus) serta tombol **Ekspor Excel**.
- Rekap, riwayat, filter periode, dan ekspor hanya muncul untuk pengguna dengan izin **Riwayat**; tanpa izin itu Beranda hanya menampilkan data hari ini.
- Menu **Akun** selalu di posisi paling bawah/terakhir di semua navigasi (sidebar, drawer, bar bawah ponsel).

## Akun saya: profil, email terverifikasi, foto
- **Profil** (menu Akun): avatar, nama, peran, kartu Email / Nomor Telepon / Status Akun, tombol *Edit Profil* dan *Pengaturan Akun*.
- **Pengaturan Akun**: *Informasi Profil* (data lengkap + info toko), *Keamanan Akun* (ubah kata sandi), *Verifikasi Email* (status, kirim ulang, ubah email), *Notifikasi* (notifikasi, bunyi, getar pesanan masuk), *Tentang Ordela* (versi 1.0.0, muat ulang versi terbaru), dan *Keluar*.
- Pengaturan Akun dikelompokkan (Akun, Aplikasi, Sesi & Privasi), tiap menu punya ikon, judul, dan deskripsi singkat; menu penting (Keamanan, Verifikasi Email) lebih besar, dan ada kolom *Cari pengaturan*.
- **Hapus Akun**: halaman peringatan, wajib kata sandi + centang persetujuan, lalu dialog konfirmasi akhir. Endpoint `DELETE /api/me`: karyawan atau owner (jika masih ada owner lain) hanya menghapus akunnya sendiri; owner tunggal menghapus seluruh toko beserta datanya, dan akun Supabase Auth ikut dihapus. **Jalankan ulang `setup.sql` di Supabase SQL Editor.**
- **Edit Profil** bisa mengubah nama, username, email, telepon, tanggal lahir, dan alamat; layar *Profil Berhasil Diperbarui* tampil setelah simpan. Owner juga bisa mengubah username, nama toko, dan nomor telepon toko. Username karyawan terkunci.
- **Ganti email** wajib verifikasi: tombol *Ubah email* meminta email baru dan sandi saat ini, lalu Supabase Auth mengirim tautan ke email baru. Email lama tetap berlaku sampai tautan dibuka; setelah itu email di aplikasi ikut berganti otomatis (trigger `pos_on_auth_email`). Server menolak perubahan email lewat `PUT /api/me`.
- **Foto profil**: ketuk avatar atau *Ubah Foto*, pilih *Ambil Foto* / *Pilih dari Galeri* / *Hapus Foto*, geser dan zoom, lalu *Simpan Foto*. Isian dan foto yang sedang diubah tidak lagi hilang saat aplikasi menyinkronkan data di latar belakang.
- Setelah mengubah `setup.sql`, jalankan ulang di Supabase SQL Editor.

## Stok opname (terhubung Excel)
- Inventori → **Stok Opname**: unduh template `.xlsx` (Kode, Nama, Kategori, Stok Sistem, Stok Fisik, Catatan), isi **Stok Fisik** di Excel/Google Sheets, lalu unggah `.xlsx` atau `.csv`.
- Item dicocokkan lewat Kode (atau Nama bila kolom Kode dihapus). Baris Stok Fisik kosong dilewati; paket (bundle) tidak ikut dihitung.
- Layar tinjau menampilkan selisih terhadap stok sistem saat ini (angka fisik masih bisa diedit, tiap baris bisa dicentang/lepas), ringkasan item, selisih total, dan nilai selisih modal.
- **Terapkan** mengubah stok dan mencatat tiap perubahan di Riwayat Perubahan Stok (`Stok opname …`). Setelah itu laporan hasil (sistem, fisik, selisih, nilai) bisa diunduh sebagai Excel.

## Payroll (khusus owner) & Absensi
- **Pengaturan → Absensi & Shift** (owner): aktifkan absensi, zona waktu, lokasi/radius toko, shift, dan shift tiap karyawan. Halaman **Absensi** kini hanya untuk absen masuk/pulang dan riwayat pribadi.
- Menu **Payroll** (owner): tab **Gaji** (periode bulanan, slip per karyawan, bonus, potongan lain/kasbon, tandai dibayar, ekspor Excel), tab **Karyawan** (jenis gaji bulanan/harian/per jam, uang makan/transport per hari hadir, tunjangan tetap, potong bila tidak hadir; aturan umum potongan telat per menit dan hari kerja per bulan), dan tab **Rekap Absensi** (ringkasan per karyawan, catatan, ekspor Excel).
- Perhitungan: pokok (tetap / harian × hari hadir / per jam × jam kerja) + makan/transport × hari hadir + tunjangan + bonus − telat (menit × tarif) − tidak hadir (gaji ÷ hari kerja × hari absen) − potongan lain. Slip yang ditandai dibayar disimpan sebagai snapshot sehingga tidak berubah bila tarif diubah.
- Data payroll disimpan di server (`GET/PUT /api/payroll`, hanya owner, dengan kontrol revisi) dan **tidak** ikut data yang disinkron ke karyawan. Jalankan ulang `setup.sql` di Supabase SQL Editor.

### Slip gaji ke email karyawan
- Slip yang sudah **ditandai dibayar** bisa dikirim ke email karyawan (tombol *Kirim Slip ke Email* di slip, atau *Kirim Semua Slip ke Email* di tab Gaji). Opsi **Kirim slip otomatis** (tab Karyawan → Aturan umum) mengirim slip begitu ditandai dibayar.
- Email dikirim server lewat Resend (`POST /api/payroll/slip`, hanya owner) dari isi slip yang tersimpan, jadi angkanya sama dengan yang dibayar. Karyawan tanpa email dilewati (mereka mengisi email sendiri di Akun → Edit Profil).
- Aktifkan sekali di Supabase SQL Editor (domain pengirim harus terverifikasi di Resend, mis. `ordela.my.id`):
  `select pos.admin_mail('re_KUNCI_API_RESEND', 'Ordela <slip@ordela.my.id>');`

## Logo & ikon

Logo resmi Ordela (piring saji bernyala) ada di folder `brand/`: `ordela-mark.svg` (simbol merah), `ordela-mark-white.svg`, `ordela-logo.svg` (untuk latar gelap),
`ordela-logo-light.svg` (untuk latar terang), serta PNG siap pakai. Ikon aplikasi (`icon-ordela-dark.svg`, `icon-ordela-red.svg`, `icon-ordela-maskable.svg`,
dan PNG `icon-192/512`, `icon-light-*`, `icon-maskable-512`) dibuat dari simbol vektor yang sama sehingga tajam di semua ukuran.
