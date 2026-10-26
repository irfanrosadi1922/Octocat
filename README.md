# Ordela
Aplikasi POS Ordela

## Pendaftaran, reset sandi, dan multi-toko (mode Supabase)

1. Unduh cadangan JSON lebih dulu (Pengaturan → Cadangan), lalu jalankan ulang `setup.sql` di Supabase → SQL Editor.
   Data lama otomatis menjadi toko nomor 1 dengan owner yang sama. Skrip aman diulang.
2. Supabase → Authentication → URL Configuration: isi **Site URL** dan **Redirect URLs** dengan alamat aplikasi (mis. `https://USERNAME.github.io/ordela/`).
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
