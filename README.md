# Ordela
Aplikasi POS Ordela

## Pendaftaran, reset sandi, dan multi-toko (mode Supabase)

1. Unduh cadangan JSON lebih dulu (Pengaturan → Cadangan), lalu jalankan ulang `setup.sql` di Supabase → SQL Editor.
   Data lama otomatis menjadi toko nomor 1 dengan owner yang sama. Skrip aman diulang.
2. Supabase → Authentication → URL Configuration: isi **Site URL** dan **Redirect URLs** dengan alamat aplikasi (`https://ordela.my.id/`; alamat lama `https://USERNAME.github.io/ordela/` boleh tetap ditambahkan di Redirect URLs selama masa peralihan).
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


## Domain sendiri: ordela.my.id
- File `CNAME` berisi `ordela.my.id`, jadi GitHub Pages melayani aplikasi di `https://ordela.my.id/`. Alamat QR pelanggan menjadi `https://ordela.my.id/order.html?s=KODETOKO`.
- DNS (di penyedia domain): buat `CNAME` untuk `www` ke `irfanrosadi1922.github.io`, dan untuk domain utama (apex) buat empat record `A` ke `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`.
- GitHub → Settings → Pages → *Custom domain*: isi `ordela.my.id`, tunggu pemeriksaan DNS selesai, lalu centang **Enforce HTTPS**.
- Supabase → Authentication → URL Configuration: ubah **Site URL** menjadi `https://ordela.my.id/` dan tambahkan `https://ordela.my.id/**` ke Redirect URLs (tautan reset sandi dan verifikasi email memakai alamat ini).
- Build APK otomatis memakai isi `CNAME` sebagai alamat QR, kecuali variabel `APP_URL` diisi.
