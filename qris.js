/* QRIS (standar EMVCo MPM, Indonesia): memeriksa QRIS statis milik toko dan membuat QRIS DINAMIS,
   yaitu salinan QRIS itu dengan nominal pesanan sudah terisi. Semua dihitung di perangkat; tidak ada data keluar. */
(function () {
  function crc16(s) {
    var c = 0xFFFF, i, j;
    for (i = 0; i < s.length; i++) { c ^= s.charCodeAt(i) << 8; for (j = 0; j < 8; j++) c = (c & 0x8000) ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF; }
    return c.toString(16).toUpperCase().padStart(4, '0');
  }
  function parse(s) {
    var out = [], i = 0, id, len;
    while (i < s.length) {
      id = s.substr(i, 2); len = parseInt(s.substr(i + 2, 2), 10);
      if (!/^\d{2}$/.test(id) || !/^\d{2}$/.test(s.substr(i + 2, 2)) || s.length < i + 4 + len) return null;
      out.push([id, s.substr(i + 4, len)]); i += 4 + len;
    }
    return out;
  }
  function tag(t, id) { for (var i = 0; i < t.length; i++) if (t[i][0] === id) return t[i][1]; return null; }
  /* hasil: {ok, err, name, dynamic, tags} */
  function check(q) {
    q = String(q == null ? '' : q).replace(/[\r\n\t]+/g, '').trim();
    if (!/^000201/.test(q)) return { ok: false, err: 'Ini bukan kode QRIS (harus diawali 000201)' };
    if (q.length > 512 || !/^[\x20-\x7E]+$/.test(q)) return { ok: false, err: 'Kode QRIS tidak valid' };
    var t = parse(q);
    if (!t) return { ok: false, err: 'Kode QRIS rusak atau terpotong, salin ulang seluruhnya' };
    var last = t[t.length - 1];
    if (!last || last[0] !== '63' || last[1].length !== 4) return { ok: false, err: 'Kode QRIS tidak lengkap (CRC hilang)' };
    if (crc16(q.slice(0, -4)) !== last[1].toUpperCase()) return { ok: false, err: 'Kode QRIS salah baca (CRC tidak cocok), salin ulang' };
    if (tag(t, '58') !== 'ID') return { ok: false, err: 'Ini bukan QRIS Indonesia' };
    return { ok: true, name: tag(t, '59') || '', dynamic: tag(t, '01') === '12', hasAmount: tag(t, '54') != null, tags: t };
  }
  /* QRIS statis + nominal -> QRIS dinamis */
  function dynamic(q, amount) {
    var c = check(q); if (!c.ok) throw new Error(c.err);
    var a = Math.round(Number(amount) * 100) / 100;
    if (!(a > 0) || a > 999999999999) throw new Error('Nominal tidak valid');
    var amt = Number.isInteger(a) ? String(a) : a.toFixed(2), t = [], ins = false, i, e;
    for (i = 0; i < c.tags.length; i++) {
      e = c.tags[i];
      if (e[0] === '63' || e[0] === '54') continue;
      if (!ins && e[0] > '54') { t.push(['54', amt]); ins = true; }
      t.push(e[0] === '01' ? ['01', '12'] : e);
    }
    if (!ins) t.push(['54', amt]);
    var body = t.map(function (x) { return x[0] + String(x[1].length).padStart(2, '0') + x[1]; }).join('') + '6304';
    return body + crc16(body);
  }
  /* baca QR dari foto (Chrome/Android; iPhone belum mendukung, pakai tempel kode) */
  function decodeImage(file) {
    if (!('BarcodeDetector' in window)) return Promise.reject(new Error('nosupport'));
    return createImageBitmap(file).then(function (bmp) {
      return new window.BarcodeDetector({ formats: ['qr_code'] }).detect(bmp).then(function (r) { return r && r[0] ? r[0].rawValue : ''; });
    });
  }
  window.QRIS = { crc16: crc16, check: check, dynamic: dynamic, decodeImage: decodeImage };
})();
