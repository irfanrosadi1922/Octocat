# Ordela
Aplikasi POS Ordela

## Pendaftaran, reset sandi, dan multi-toko (mode Supabase)

1. Unduh cadangan JSON lebih dulu (Pengaturan → Cadangan), lalu jalankan ulang `setup.sql` di Supabase → SQL Editor.
   Data lama otomatis menjadi toko nomor 1 dengan owner yang sama. Skrip aman diulang.
2. Supabase → Authentication → URL Configuration: isi **Site URL** dan **Redirect URLs** dengan alamat aplikasi (mis. `https://USERNAME.github.io/ordela/`).
3. Authentication → Sign In / Providers → Email: biarkan **Confirm email** menyala (verifikasi boleh nanti, login tidak diblokir), set panjang sandi minimal 8.
4. Authentication → Emails: sesuaikan template *Confirm signup* dan *Reset password*; pasang SMTP sendiri untuk pengiriman nyata (SMTP bawaan sangat terbatas).
5. Opsional: aktifkan CAPTCHA di Authentication → Attack Protection (pengaturan dashboard, tanpa kode).
