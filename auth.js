/* Ordela — pendaftaran akun, verifikasi email, reset sandi lewat email, dan penyiapan toko.
   Hanya aktif di mode Supabase (window.POS_SB terisi). Email & sandi dikelola Supabase Auth (GoTrue, lewat fetch biasa);
   sesi aplikasi tetap sesi Ordela (lihat setup.sql: pos.login). Dimuat setelah skrip utama di index.html. */
(function(){
'use strict';
const SB=globalThis.POS_SB;
if(!SB||!SB.url||!SB.key||typeof $==='undefined')return;
document.documentElement.classList.add('hasauth');

/* ---------- util ---------- */
const E=s=>esc(s);
const EMAIL_RE=/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const USER_RE=/^[a-z0-9][a-z0-9._-]{2,23}$/;
const REDIR=location.origin+location.pathname;
const RESEND_KEY='pos_resend_t',FORGOT_KEY='pos_forgot_t',COOL=60;
async function gt(path,o){
  o=o||{};
  const h={'Content-Type':'application/json',apikey:SB.key};
  if(o.bearer)h.Authorization='Bearer '+o.bearer;
  const r=await fetch(SB.url+'/auth/v1'+path,{method:o.method||'POST',headers:h,body:o.body?JSON.stringify(o.body):undefined,cache:'no-store'});
  let j={};try{j=await r.json()}catch(e){}
  return{ok:r.ok,status:r.status,j};
}
function gtErr(r){
  const c=(r.j&&(r.j.error_code||r.j.code))||'',m=String((r.j&&(r.j.msg||r.j.message||r.j.error_description))||'');
  if(r.status===429||/rate_limit|too many|security purposes/i.test(c+m))return'Terlalu sering mencoba. Tunggu beberapa menit lalu coba lagi.';
  if(/user_already_exists|email_exists|already registered/i.test(c+m))return'Email ini sudah terdaftar.';
  if(/weak_password|password/i.test(c+m)&&r.status===422)return'Kata sandi terlalu lemah. Gunakan minimal 8 karakter dengan huruf dan angka.';
  if(/signup_disabled/i.test(c+m))return'Pendaftaran sedang dinonaktifkan.';
  if(/Database error/i.test(m))return'Username sudah dipakai atau data tidak valid. Periksa kembali.';
  if(/email/i.test(m)&&r.status===400||/validation_failed/.test(c))return'Alamat email tidak valid.';
  if(/otp_expired|expired|invalid/i.test(c+m))return'Tautan sudah kedaluwarsa atau tidak valid. Minta tautan baru.';
  return'Permintaan gagal. Coba lagi sebentar lagi.';
}
async function rc(body){ // register/check lewat RPC (tanpa login)
  try{const r=await fetch('/api/register/check',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    if(r.status===429)return{limited:true};if(!r.ok)return null;return await r.json()}catch(e){return null}
}
const now=()=>Date.now();
function cdLeft(k){let t=0;try{t=+localStorage.getItem(k)||0}catch(e){}return Math.max(0,Math.ceil((t+COOL*1000-now())/1000))}
function cdSet(k){try{localStorage.setItem(k,String(now()))}catch(e){}}
function pwOk(p){return typeof p==='string'&&p.length>=8&&p.length<=72&&/[A-Za-z]/.test(p)&&/\d/.test(p)}
function eye(id){return`<div class="pw"><input class="fi" type="password" id="${id}" autocomplete="new-password" maxlength="72"><button type="button" class="eye" onclick="authEye('${id}',this)">Tampilkan</button></div>`}
window.authEye=function(id,b){const i=document.getElementById(id);if(!i)return;const s=i.type==='password';i.type=s?'text':'password';b.textContent=s?'Sembunyikan':'Tampilkan'};

/* ---------- gaya ---------- */
const st=document.createElement('style');
st.textContent=`
.authw{z-index:230!important}
.authc{max-width:420px!important}
.authc h2{margin:0 0 4px;font-size:21px;text-align:center}
.authc .lsub{text-align:center;margin:0 0 6px}
.authc .fe{color:var(--bad);font-size:12px;min-height:16px;margin:4px 0 0}
.authc .ok{color:var(--ok,#15803d)}
.authc .row2{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:8px}
.authc .row2 .fi{min-width:0}
.authc textarea.fi{min-height:64px;resize:vertical;font:inherit}
.authc .hp{position:absolute;left:-9999px;opacity:0;height:0;width:0}
.authc .alt{display:block;text-align:center;margin:14px 0 0;font-size:13px;color:var(--mu)}
.authc .alt a,.lfoot a{color:var(--tx,#111);font-weight:700;text-decoration:underline;cursor:pointer}
.lfoot.two{display:flex;flex-direction:column;gap:6px}
.vbar{position:fixed;left:0;right:0;top:0;z-index:120;display:flex;align-items:center;gap:10px;justify-content:center;height:34px;box-sizing:content-box;padding:env(safe-area-inset-top,0px) 12px 0;background:#111;color:#fff;font-size:12.5px;line-height:1.35;text-align:center}
.vbar button{background:#fff;color:#111;border-radius:999px;padding:4px 12px;font-weight:700;font-size:12px}
.vbar button:disabled{opacity:.55}
html.hasvb body{padding-top:calc(34px + env(safe-area-inset-top,0px))}
.vbar .x{background:transparent;color:#fff;padding:2px 8px;font-size:16px}
.vst{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:6px 0 0;font-size:12.5px}
.vst b{padding:2px 10px;border-radius:999px;font-size:11.5px}
.vst b.y{background:#dcfce7;color:#15803d}.vst b.n{background:#fee2e2;color:#b91c1c}
.vst .lnk{font-size:12.5px}
.vst .lnk2{background:none;color:var(--tx);font-size:12.5px;font-weight:700;text-decoration:underline;padding:2px 0}
.vst .pend{flex-basis:100%;font-size:12.5px;color:var(--tx2);background:var(--peach);border-radius:10px;padding:8px 10px;line-height:1.45}
.wz{display:flex;gap:6px;justify-content:center;margin:0 0 10px}.wz i{width:28px;height:4px;border-radius:2px;background:var(--ln,#ddd)}.wz i.on{background:#111}
.lgup{display:flex;align-items:center;gap:12px;margin-top:6px}.lgup .lpv{width:64px;height:64px;border-radius:50%;border:1.5px dashed var(--ln,#ccc);display:flex;align-items:center;justify-content:center;overflow:hidden;background:var(--bg,#f5f5f5);flex:none}.lgup .lpv img{width:100%;height:100%;object-fit:cover}
`;
document.head.appendChild(st);

/* ---------- lapisan layar ---------- */
let ov=null;
function show(html){
  if(!ov){ov=document.createElement('div');ov.className='loginw authw';ov.id='authw';document.body.appendChild(ov)}
  ov.innerHTML='<form class="loginc authc" autocomplete="on" onsubmit="return false">'+html+'</form>';ov.hidden=false;
  const f=ov.querySelector('form');f.addEventListener('submit',e=>e.preventDefault());
  ov.scrollTop=0;return f;
}
function hide(){if(ov){ov.hidden=true;ov.innerHTML=''}}
const brand=()=>`<img src="${E((db&&db.set&&db.set.logo)||DEF_LOGO)}" alt="" style="width:64px;height:64px">`;
function setBusy(b,on,txt){if(!b)return;b.disabled=on;if(txt!=null){if(on){b.dataset.t=b.textContent;b.textContent=txt}else b.textContent=b.dataset.t||b.textContent}}
const val=id=>(document.getElementById(id)||{}).value||'';
const msg=(t,ok)=>{const e=document.getElementById('aErr');if(e){e.textContent=t||'';e.classList.toggle('ok',!!ok)}};

/* ---------- daftar ---------- */
window.authRegister=function(){
  const f=show(`${brand()}<h2>Buat akun</h2>
  <label class="fl" for="rName">Nama lengkap</label><input class="fi" id="rName" maxlength="60" autocomplete="name" placeholder="Nama sesuai identitas">
  <label class="fl" for="rUser">Username</label><input class="fi" id="rUser" maxlength="24" autocomplete="username" autocapitalize="none" autocorrect="off" spellcheck="false" placeholder="huruf kecil, angka, . _ -">
  <p class="fe" id="rUserE"></p>
  <label class="fl" for="rEmail">Alamat email</label><input class="fi" id="rEmail" type="email" inputmode="email" maxlength="120" autocomplete="email" autocapitalize="none" placeholder="nama@contoh.com">
  <p class="fe" id="rEmailE"></p>
  <label class="fl">Nomor telepon <span style="font-weight:400">(opsional)</span></label>
  <div class="phr"><select class="fi" id="rCc" aria-label="Kode negara">${phCcOpts(phDefCc())}</select><input class="fi" id="rPhone" type="tel" inputmode="tel" maxlength="14" placeholder="812 3456 7890" autocomplete="tel-national"></div>
  <label class="fl" for="rBirth">Tanggal lahir <span style="font-weight:400">(opsional)</span></label><input class="fi" id="rBirth" type="date" autocomplete="bday">
  <label class="fl" for="rAddr">Alamat <span style="font-weight:400">(opsional)</span></label><textarea class="fi" id="rAddr" maxlength="300" autocomplete="street-address" placeholder="Jalan, kota"></textarea>
  <label class="fl" for="rPw">Kata sandi</label>${eye('rPw')}
  <p class="hint" style="margin:4px 0 0;font-size:12px;color:var(--mu)">Minimal 8 karakter, berisi huruf dan angka.</p>
  <label class="fl" for="rPw2">Ulangi kata sandi</label>${eye('rPw2')}
  <input class="hp" id="rHp" tabindex="-1" autocomplete="off" aria-hidden="true">
  <p class="fe" id="aErr" role="alert"></p>
  <button class="btn" id="rBtn" type="submit">Daftar</button>
  <span class="alt">Sudah punya akun? <a onclick="authLoginBack()">Masuk</a></span>`);
  $('#login').hidden=true;
  let tm=0;
  const chkU=async()=>{const u=val('rUser').trim().toLowerCase(),e=$('#rUserE');if(!u){e.textContent='';return true}
    if(!USER_RE.test(u)){e.textContent='Username 3-24 karakter: huruf kecil, angka, titik, strip, garis bawah.';return false}
    const r=await rc({username:u});if(!r){e.textContent='';return true}if(r.limited){e.textContent='Terlalu banyak pengecekan, tunggu sebentar.';return true}
    e.textContent=r.usernameFree?'':'Username sudah dipakai.';return !!r.usernameFree};
  const chkE=async()=>{const m=val('rEmail').trim().toLowerCase(),e=$('#rEmailE');if(!m){e.textContent='';return true}
    if(!EMAIL_RE.test(m)){e.textContent='Format email tidak valid.';return false}
    const r=await rc({email:m});if(!r||r.limited){e.textContent='';return true}
    e.textContent=r.emailFree?'':'Email ini sudah terdaftar. Gunakan "Lupa sandi" bila perlu.';return !!r.emailFree};
  $('#rUser').addEventListener('blur',chkU);$('#rEmail').addEventListener('blur',chkE);
  $('#rUser').addEventListener('input',()=>{clearTimeout(tm);tm=setTimeout(chkU,600)});
  $('#rPhone').addEventListener('input',e=>{e.target.value=phFmt(e.target.value)});
  f.addEventListener('submit',async()=>{
    const b=$('#rBtn');msg('');
    const name=val('rName').trim().replace(/\s+/g,' '),un=val('rUser').trim().toLowerCase(),em=val('rEmail').trim().toLowerCase(),
      pw=val('rPw'),pw2=val('rPw2'),ph=val('rPhone').replace(/\D/g,''),birth=val('rBirth'),addr=val('rAddr').trim();
    if(val('rHp'))return;
    if(name.length<2||name.length>60)return msg('Nama lengkap wajib diisi (2-60 karakter).');
    if(!USER_RE.test(un))return msg('Username tidak valid.');
    if(!EMAIL_RE.test(em))return msg('Alamat email tidak valid.');
    if(ph&&ph.length<6)return msg('Nomor telepon tidak valid.');
    if(birth){const d=new Date(birth);if(isNaN(d)||d>new Date()||d.getFullYear()<1900)return msg('Tanggal lahir tidak valid.')}
    if(!pwOk(pw))return msg('Kata sandi minimal 8 karakter, berisi huruf dan angka.');
    if(pw!==pw2)return msg('Ulangi kata sandi dengan sama persis.');
    setBusy(b,true,'Mendaftar…');
    try{
      if(!(await chkU())||!(await chkE()))return msg('Perbaiki isian yang ditandai.');
      const phone=ph?'+'+val('rCc')+' '+phFmt(ph.replace(/^0+/,'')):'';
      const r=await gt('/signup?redirect_to='+encodeURIComponent(REDIR),{body:{email:em,password:pw,data:{username:un,name,phone,birth,address:addr}}});
      if(!r.ok)return msg(gtErr(r));
      const u=r.j&&(r.j.user||r.j);
      if(u&&Array.isArray(u.identities)&&u.identities.length===0)return msg('Email ini sudah terdaftar.');
      // Jangan otomatis login setelah daftar. Akun harus membuka tautan verifikasi email terlebih dahulu.
      try{if(r.j&&r.j.session&&r.j.session.access_token)await gt('/logout',{bearer:r.j.session.access_token})}catch(e){}
      try{cdSet(RESEND_KEY)}catch(e){}
      hide();showLogin();
      toast('Akun berhasil dibuat. Buka email dan verifikasi alamat email sebelum masuk. Periksa folder spam jika belum terlihat.');
    }catch(e){msg('Tidak bisa terhubung. Periksa koneksi lalu coba lagi.')}
    finally{setBusy(b,false)}
  });
  setTimeout(()=>$('#rName').focus(),60);
};
window.authLoginBack=function(){hide();showLogin()};

/* ---------- lupa sandi ---------- */
window.authForgot=function(){
  const f=show(`${brand()}<h2>Lupa kata sandi</h2><p class="lsub">Masukkan email akun Anda. Kami kirim tautan untuk membuat sandi baru.</p>
  <label class="fl" for="fEmail">Alamat email</label><input class="fi" id="fEmail" type="email" inputmode="email" autocomplete="email" autocapitalize="none" maxlength="120" placeholder="nama@contoh.com">
  <p class="fe" id="aErr" role="alert"></p>
  <button class="btn" id="fBtn" type="submit">Kirim tautan</button>
  <span class="alt"><a onclick="authLoginBack()">Kembali masuk</a></span>`);
  $('#login').hidden=true;
  f.addEventListener('submit',async()=>{
    const em=val('fEmail').trim().toLowerCase(),b=$('#fBtn');msg('');
    if(!EMAIL_RE.test(em))return msg('Alamat email tidak valid.');
    const left=cdLeft(FORGOT_KEY);if(left>0)return msg('Tunggu '+left+' detik sebelum meminta tautan lagi.');
    setBusy(b,true,'Mengirim…');cdSet(FORGOT_KEY);
    try{await gt('/recover?redirect_to='+encodeURIComponent(REDIR),{body:{email:em}})}catch(e){}
    setBusy(b,false);
    msg('Jika email terdaftar, tautan telah dikirim. Periksa kotak masuk dan folder spam.',true);
  });
  setTimeout(()=>$('#fEmail').focus(),60);
};

/* ---------- buat sandi baru (dari tautan di email) ---------- */
function newPwScreen(token){
  const f=show(`${brand()}<h2>Buat sandi baru</h2>
  <label class="fl" for="nPw">Kata sandi baru</label>${eye('nPw')}
  <label class="fl" for="nPw2">Ulangi kata sandi</label>${eye('nPw2')}
  <p class="hint" style="margin:4px 0 0;font-size:12px;color:var(--mu)">Minimal 8 karakter, berisi huruf dan angka.</p>
  <p class="fe" id="aErr" role="alert"></p>
  <button class="btn" id="nBtn" type="submit">Simpan sandi</button>`);
  $('#login').hidden=true;
  f.addEventListener('submit',async()=>{
    const p=val('nPw'),b=$('#nBtn');msg('');
    if(!pwOk(p))return msg('Kata sandi minimal 8 karakter, berisi huruf dan angka.');
    if(p!==val('nPw2'))return msg('Ulangi kata sandi dengan sama persis.');
    setBusy(b,true,'Menyimpan…');
    try{
      const r=await gt('/user',{method:'PUT',bearer:token,body:{password:p}});
      if(!r.ok)return msg(gtErr(r));
      hide();showLogin('Sandi berhasil diperbarui. Masuk dengan sandi baru.');
    }catch(e){msg('Tidak bisa terhubung. Coba lagi.')}
    finally{setBusy(b,false)}
  });
  setTimeout(()=>$('#nPw').focus(),60);
}

/* ---------- tautan dari email (hash di URL) ---------- */
function readHash(){
  const h=location.hash.replace(/^#/,'');if(!h||!/(access_token|error)=/.test(h))return null;
  const p=new URLSearchParams(h);
  try{history.replaceState(null,'',location.pathname+location.search)}catch(e){}
  return Object.fromEntries(p.entries());
}
function handleHash(){
  const p=readHash();if(!p)return;
  if(p.error||p.error_code){toast(/expired|invalid/i.test((p.error_code||'')+(p.error_description||''))?'Tautan sudah kedaluwarsa. Minta tautan baru.':'Tautan tidak valid.');
    if(p.type==='recovery'||/recover/i.test(p.error_description||''))setTimeout(authForgot,300);return}
  if(p.type==='recovery'&&p.access_token){newPwScreen(p.access_token);return}
  if(p.type==='signup'||p.type==='email_change'||p.type==='invite'||p.type==='magiclink'){toast('Email berhasil diverifikasi');setTimeout(async()=>{try{await refreshMe();renderAccVerif();if(S.view==='acc')renderAccPage()}catch(e){}},400)}
}

/* ---------- spanduk verifikasi email ---------- */
let vbar=null,vtick=0;
function vRender(){
  const m=CL&&CL.me,need=!!(CL.on&&CL.tok&&m&&m.hasAuth&&!m.emailVerified);
  let dis='';try{dis=sessionStorage.getItem('pos_vbar_x')||''}catch(e){}
  if(!need||dis){if(vbar){vbar.remove();vbar=null}document.documentElement.classList.remove('hasvb');clearInterval(vtick);return}
  if(!vbar){vbar=document.createElement('div');vbar.className='vbar';vbar.id='vbar';document.body.appendChild(vbar)}
  document.documentElement.classList.add('hasvb');
  const left=cdLeft(RESEND_KEY);
  vbar.innerHTML=`<span>Email belum diverifikasi.</span><button type="button" id="vRs" ${left?'disabled':''}>${left?'Kirim ulang ('+left+' dtk)':'Kirim ulang'}</button><button class="x" type="button" aria-label="Tutup" id="vX">×</button>`;
  $('#vRs').onclick=authResend;$('#vX').onclick=()=>{try{sessionStorage.setItem('pos_vbar_x','1')}catch(e){}vRender()};
  clearInterval(vtick);if(left)vtick=setInterval(vRender,1000);
}
window.authResend=async function(){
  const m=CL.me;if(!m||!m.email)return;if(cdLeft(RESEND_KEY)>0)return;
  cdSet(RESEND_KEY);vRender();
  try{const r=await gt('/resend?redirect_to='+encodeURIComponent(REDIR),{body:{type:'signup',email:m.email}});
    toast(r.ok?'Email verifikasi dikirim ulang':gtErr(r))}catch(e){toast('Tidak bisa terhubung')}
  renderAccVerif();
};

/* ---------- status verifikasi + ubah/tambah email di halaman Profil ---------- */
function renderAccVerif(){
  const m=CL.me;if(!m)return;
  for(const id of ['accVst','accVstV']){
    const box=document.getElementById(id);if(!box)continue;
    const left=cdLeft(RESEND_KEY),edit=id==='accVst';
    let h='';
    if(m.hasAuth){
      h+=m.emailVerified?'<b class="y">Terverifikasi</b>':'<b class="n">Belum diverifikasi</b>';
      if(!m.emailVerified)h+=`<button class="lnk" type="button" ${left?'disabled':''} onclick="authResend()">${left?'Kirim ulang ('+left+' dtk)':'Kirim ulang email verifikasi'}</button>`;
      if(m.pendingEmail)h+=`<span class="pend">Menunggu verifikasi email baru <b>${E(m.pendingEmail)}</b>. Buka tautan yang kami kirim ke sana.</span><button class="lnk" type="button" ${left?'disabled':''} onclick="authResendChange()">${left?'Kirim ulang ('+left+' dtk)':'Kirim ulang tautan'}</button>`;
      h+=`<button class="lnk2" type="button" onclick="authChangeEmail()">Ubah email</button>`;
      if(edit)h+='<span class="hint" style="flex-basis:100%">Email baru baru berlaku setelah Anda membuka tautan verifikasi yang dikirim ke alamat itu.</span>';
    }else{
      h+=`<span style="color:var(--mu)">${m.email?'Email belum terhubung ke akun.':'Akun ini belum memakai email.'}</span><button class="lnk2" type="button" onclick="authAddEmail()">${m.email?'Hubungkan &amp; verifikasi email':'Tambah email'}</button>`;
    }
    box.className='vst';box.innerHTML=h;
  }
}
window.renderAccVerif=renderAccVerif;
window.authResendChange=async function(){
  const m=CL.me;if(!m||!m.pendingEmail||cdLeft(RESEND_KEY)>0)return;
  cdSet(RESEND_KEY);renderAccVerif();
  try{const r=await gt('/resend?redirect_to='+encodeURIComponent(REDIR),{body:{type:'email_change',email:m.pendingEmail}});
    toast(r.ok?'Tautan verifikasi dikirim ulang ke '+m.pendingEmail:gtErr(r))}catch(e){toast('Tidak bisa terhubung')}
  renderAccVerif();
};
/* ubah email: butuh sandi saat ini (masuk ke Supabase Auth), lalu tautan verifikasi dikirim ke email BARU */
window.authChangeEmail=function(){
  const m=CL.me;if(!m||!m.hasAuth)return;
  const f=show(`<h2>Ubah email</h2><p class="lsub">Email saat ini: <b>${E(m.email)}</b>. Kami kirim tautan verifikasi ke email baru; email lama tetap dipakai sampai tautan itu dibuka.</p>
  <label class="fl" for="cEm">Alamat email baru</label><input class="fi" id="cEm" type="email" inputmode="email" autocomplete="email" autocapitalize="none" maxlength="120" placeholder="nama@contoh.com">
  <label class="fl" for="cPw">Kata sandi saat ini</label><div class="pw"><input class="fi" type="password" id="cPw" autocomplete="current-password" maxlength="72"><button type="button" class="eye" onclick="authEye('cPw',this)">Tampilkan</button></div>
  <p class="fe" id="aErr" role="alert"></p>
  <button class="btn" id="cBtn" type="submit">Kirim tautan verifikasi</button>
  <span class="alt"><a onclick="authClose()">Batal</a></span>`);
  f.addEventListener('submit',async()=>{
    const em=val('cEm').trim().toLowerCase(),pw=val('cPw'),b=$('#cBtn');msg('');
    if(!EMAIL_RE.test(em)||em.length>120)return msg('Alamat email tidak valid.');
    if(em===String(m.email||'').toLowerCase())return msg('Itu sudah email Anda saat ini.');
    if(!pw)return msg('Isi kata sandi saat ini.');
    if(cdLeft(RESEND_KEY)>0)return msg('Tunggu sebentar sebelum mencoba lagi.');
    setBusy(b,true,'Mengirim…');
    try{
      const ck=await rc({email:em});if(ck&&ck.limited)return msg('Terlalu sering mencoba. Coba lagi nanti.');if(ck&&ck.emailFree===false)return msg('Email ini sudah dipakai akun lain.');
      const t=await gt('/token?grant_type=password',{body:{email:m.email,password:pw}});
      if(!t.ok){const c=String((t.j&&(t.j.error_code||t.j.code))||'')+String((t.j&&(t.j.msg||t.j.error_description))||'');
        return msg(/email_not_confirmed|not confirmed/i.test(c)?'Verifikasi email lama Anda dulu (kirim ulang tautan di halaman Profil), baru ganti email.':/invalid|credentials/i.test(c)?'Kata sandi salah.':gtErr(t))}
      const u=await gt('/user?redirect_to='+encodeURIComponent(REDIR),{method:'PUT',bearer:t.j.access_token,body:{email:em}});
      if(!u.ok)return msg(gtErr(u));
      cdSet(RESEND_KEY);hide();
      try{await refreshMe()}catch(e){}
      renderAccVerif();vRender();
      toast('Tautan verifikasi dikirim ke '+em+'. Buka tautan itu untuk menyelesaikan.');
    }catch(e){if(e&&e.message!=='auth')msg('Tidak bisa terhubung. Coba lagi.')}
    finally{setBusy(b,false)}
  });
  setTimeout(()=>$('#cEm').focus(),60);
};
window.authAddEmail=function(){
  const f=show(`<h2>Tambah email</h2><p class="lsub">Email dipakai untuk reset sandi. Verifikasi bisa dilakukan nanti.</p>
  <label class="fl" for="aEm">Alamat email</label><input class="fi" id="aEm" type="email" inputmode="email" autocomplete="email" autocapitalize="none" maxlength="120" placeholder="nama@contoh.com">
  <label class="fl" for="aPw">Kata sandi saat ini</label><div class="pw"><input class="fi" type="password" id="aPw" autocomplete="current-password" maxlength="72"><button type="button" class="eye" onclick="authEye('aPw',this)">Tampilkan</button></div>
  <p class="hint" style="margin:4px 0 0;font-size:12px;color:var(--mu)">Sandi ini juga menjadi sandi akun Anda yang baru terhubung ke email (minimal 8 karakter, huruf dan angka).</p>
  <p class="fe" id="aErr" role="alert"></p>
  <button class="btn" id="aBtn" type="submit">Tambah email</button>
  <span class="alt"><a onclick="authClose()">Batal</a></span>`);
  f.addEventListener('submit',async()=>{
    const em=val('aEm').trim().toLowerCase(),pw=val('aPw'),b=$('#aBtn');msg('');
    if(!EMAIL_RE.test(em))return msg('Alamat email tidak valid.');
    if(!pwOk(pw))return msg('Sandi saat ini harus minimal 8 karakter berisi huruf dan angka. Ubah sandi dulu di menu "Ubah password" bila lebih pendek.');
    setBusy(b,true,'Menyimpan…');
    try{
      const ck=await rc({email:em});if(ck&&ck.emailFree===false)return msg('Email ini sudah terdaftar.');
      const r=await gt('/signup?redirect_to='+encodeURIComponent(REDIR),{body:{email:em,password:pw,data:{kind:'link'}}});
      if(!r.ok)return msg(gtErr(r));
      const u=r.j&&(r.j.user||r.j);if(u&&Array.isArray(u.identities)&&u.identities.length===0)return msg('Email ini sudah terdaftar.');
      const r2=await api('/api/me/link-email',{method:'POST',body:JSON.stringify({email:em,password:pw})});
      const j=await r2.json().catch(()=>({}));
      if(!r2.ok)return msg(j.error||'Gagal menambahkan email.');
      setMe(j);cdSet(RESEND_KEY);hide();applyAccess();if(S.view==='acc')renderAccPage();
      toast('Email ditambahkan. Cek kotak masuk untuk verifikasi.');
    }catch(e){if(e&&e.message!=='auth')msg('Tidak bisa terhubung. Coba lagi.')}
    finally{setBusy(b,false)}
  });
  setTimeout(()=>$('#aEm').focus(),60);
};
window.authClose=hide;


/* ---------- penyiapan toko (akun baru) ---------- */
const WZ={step:1,name:'',addr:'',phone:'',cc:'',cur:'',tz:'',tax:'0',logo:''};
const TZS=[['Asia/Jakarta','WIB · Jakarta'],['Asia/Makassar','WITA · Makassar'],['Asia/Jayapura','WIT · Jayapura'],['Asia/Kuala_Lumpur','Malaysia'],['Asia/Singapore','Singapura'],['Asia/Brunei','Brunei'],['Asia/Bangkok','Thailand'],['Asia/Manila','Filipina']];
const CURS=[['Rp','Rupiah (Rp)'],['RM','Ringgit (RM)'],['S$','Dolar Singapura (S$)'],['B$','Dolar Brunei (B$)'],['฿','Baht (฿)'],['₱','Peso (₱)'],['$','Dolar ($)']];
function wzDefaults(){
  if(WZ.tz)return;let z='';try{z=Intl.DateTimeFormat().resolvedOptions().timeZone||''}catch(e){}
  WZ.tz=TZS.some(x=>x[0]===z)?z:'Asia/Jakarta';
  WZ.cc=phDefCc();WZ.cur=/Kuala_Lumpur/.test(WZ.tz)?'RM':/Singapore/.test(WZ.tz)?'S$':/Brunei/.test(WZ.tz)?'B$':/Bangkok/.test(WZ.tz)?'฿':/Manila/.test(WZ.tz)?'₱':'Rp';
}
function wzDots(){return'<div class="wz">'+[1,2,3].map(i=>`<i class="${i<=WZ.step?'on':''}"></i>`).join('')+'</div>'}
window.authWizard=function(){
  wzDefaults();
  const m=CL.me||{};
  if(!WZ.name&&m.name)WZ.name='';
  const hdr=`<i id="wzOn" hidden></i>${wzDots()}`;
  const out=`<span class="alt"><a onclick="cloudLogout()">Keluar</a></span>`;
  let f;
  if(WZ.step===1){
    f=show(`${hdr}<h2>Siapkan toko Anda</h2><p class="lsub">Langkah 1 dari 3 · Informasi toko</p>
    <label class="fl" for="wName">Nama toko</label><input class="fi" id="wName" maxlength="60" value="${E(WZ.name)}" placeholder="mis. Kedai Melati" autocomplete="organization">
    <label class="fl" for="wAddr">Alamat toko</label><textarea class="fi" id="wAddr" maxlength="300" placeholder="Jalan, kota">${E(WZ.addr)}</textarea>
    <label class="fl">Nomor telepon toko <span style="font-weight:400">(opsional)</span></label>
    <div class="phr"><select class="fi" id="wCc">${phCcOpts(WZ.cc)}</select><input class="fi" id="wPhone" type="tel" inputmode="tel" maxlength="14" value="${E(WZ.phone)}" placeholder="812 3456 7890"></div>
    <p class="fe" id="aErr" role="alert"></p><button class="btn" type="submit">Lanjut</button>${out}`);
    $('#wPhone').addEventListener('input',e=>{e.target.value=phFmt(e.target.value)});
    f.addEventListener('submit',()=>{
      WZ.name=val('wName').trim().replace(/\s+/g,' ');WZ.addr=val('wAddr').trim();WZ.cc=val('wCc');WZ.phone=val('wPhone');
      if(WZ.name.length<2)return msg('Nama toko wajib diisi (min. 2 karakter).');
      if(WZ.phone&&WZ.phone.replace(/\D/g,'').length<6)return msg('Nomor telepon tidak valid.');
      WZ.step=2;authWizard()});
  }else if(WZ.step===2){
    f=show(`${hdr}<h2>Pengaturan dasar</h2><p class="lsub">Langkah 2 dari 3 · Mata uang, zona waktu, pajak</p>
    <label class="fl" for="wCur">Mata uang</label><select class="fi" id="wCur">${CURS.map(c=>`<option value="${E(c[0])}" ${c[0]===WZ.cur?'selected':''}>${E(c[1])}</option>`).join('')}</select>
    <label class="fl" for="wTz">Zona waktu</label><select class="fi" id="wTz">${TZS.map(c=>`<option value="${c[0]}" ${c[0]===WZ.tz?'selected':''}>${E(c[1])}</option>`).join('')}</select>
    <label class="fl" for="wTax">Pajak (%)</label><input class="fi" id="wTax" type="number" inputmode="decimal" min="0" max="50" step="0.5" value="${E(WZ.tax)}">
    <p class="fe" id="aErr" role="alert"></p>
    <div class="row2"><button class="btn sec" type="button" id="wBack">Kembali</button><button class="btn" type="submit">Lanjut</button></div>${out}`);
    $('#wBack').onclick=()=>{WZ.step=1;authWizard()};
    f.addEventListener('submit',()=>{
      WZ.cur=val('wCur');WZ.tz=val('wTz');WZ.tax=val('wTax')||'0';
      const x=parseFloat(WZ.tax);if(isNaN(x)||x<0||x>50)return msg('Pajak harus 0 sampai 50.');
      WZ.step=3;authWizard()});
  }else{
    f=show(`${hdr}<h2>Logo toko</h2><p class="lsub">Langkah 3 dari 3 · Opsional, bisa diubah nanti</p>
    <div class="lgup"><span class="lpv" id="wPv">${WZ.logo?`<img src="${E(WZ.logo)}" alt="">`:'<small style="color:var(--mu)">Logo</small>'}</span>
      <div><button class="btn sec sm" type="button" onclick="document.getElementById('wFile').click()">Pilih gambar</button> <button class="lnk" type="button" id="wRm" ${WZ.logo?'':'hidden'}>Hapus</button></div></div>
    <input type="file" id="wFile" accept="image/*" hidden>
    <p class="hint" style="font-size:12px;color:var(--mu)">Toko dimulai kosong: Anda mengisi menu dan produk sendiri setelah ini.</p>
    <p class="fe" id="aErr" role="alert"></p>
    <div class="row2"><button class="btn sec" type="button" id="wBack">Kembali</button><button class="btn" id="wGo" type="submit">Selesai</button></div>${out}`);
    $('#wBack').onclick=()=>{WZ.step=2;authWizard()};
    $('#wRm').onclick=()=>{WZ.logo='';authWizard()};
    $('#wFile').onchange=e=>{const fl=e.target.files&&e.target.files[0];if(!fl)return;
      if(!/^image\//.test(fl.type))return msg('File harus berupa gambar.');
      const rd=new FileReader();rd.onload=()=>{const im=new Image();im.onload=()=>{try{
        const N=256,c=document.createElement('canvas');c.width=c.height=N;const x=c.getContext('2d');
        const sz=Math.min(im.width,im.height);x.fillStyle='#fff';x.fillRect(0,0,N,N);x.drawImage(im,(im.width-sz)/2,(im.height-sz)/2,sz,sz,0,0,N,N);
        WZ.logo=c.toDataURL('image/jpeg',.85);authWizard()}catch(er){msg('Gambar tidak bisa diproses.')}};
        im.onerror=()=>msg('Gambar tidak bisa dibaca.');im.src=rd.result};rd.readAsDataURL(fl)};
    f.addEventListener('submit',wzFinish);
  }
};
async function wzFinish(){
  const b=$('#wGo');setBusy(b,true,'Menyiapkan…');msg('');
  try{
    const r=await api('/api/store/setup',{method:'POST',body:JSON.stringify({name:WZ.name,tz:WZ.tz})});
    const j=await r.json().catch(()=>({}));
    if(!r.ok)return msg(j.error||'Gagal menyiapkan toko. Coba lagi.');
    setMe(j);
    try{if(j.store&&j.store.code)localStorage.setItem('pos_dbstore',j.store.code)}catch(e){}   // data lokal berikut milik toko baru ini
    const d=seed();d.items=[];d.cats=[];d.orders=[];d.log=[];d.seq=1;
    const dec=WZ.cur==='Rp'||WZ.cur==='₱'?0:2;
    d.set={...d.set,store:WZ.name,addr:WZ.addr,phone:WZ.phone?'+'+WZ.cc+' '+WZ.phone:'',tax:parseFloat(WZ.tax)||0,cur:WZ.cur,dec,logo:WZ.logo,tz:WZ.tz};
    delete d._ts;
    db=fixDb(d);S.cart={};S.sel.clear();CL.ver=0;CL.dirty=true;persistMeta();save();applyBrand();
    hide();Object.assign(WZ,{step:1,name:'',addr:'',phone:'',logo:''});
    applyAccess();go('pos');syncNow();toast('Toko siap. Mulai tambahkan menu Anda.');
  }catch(e){if(e&&e.message!=='auth')msg('Tidak bisa terhubung. Coba lagi.')}
  finally{setBusy(b,false)}
}

/* ---------- kaitkan ke aplikasi ---------- */
function patchLogin(){
  const l=document.querySelector('label[for=loginUser]');if(l)l.textContent='Username atau email';
  const i=$('#loginUser');if(i)i.placeholder='username atau email@contoh.com';
  const lf=document.querySelector('#login .lfoot');
  if(lf){lf.classList.add('two');lf.innerHTML='<span><a onclick="authForgot()">Lupa sandi?</a></span><span>Belum punya akun? <a onclick="authRegister()">Daftar</a></span>'}
}
const _aa=window.applyAccess;
window.applyAccess=function(){_aa.apply(this,arguments);vRender();authGate()};
const _ra=window.renderAccPage;
window.renderAccPage=function(){_ra.apply(this,arguments);renderAccVerif()};
const _sn=window.syncNow;
window.syncNow=function(){if(CL.me&&CL.me.role==='new')return;return _sn.apply(this,arguments)};
const _cl=window.cloudLogout;
window.cloudLogout=function(){try{sessionStorage.removeItem('pos_vbar_x')}catch(e){}hide();return _cl.apply(this,arguments)};

function authGate(){ // akun baru tanpa toko -> penyiapan toko
  if(CL.on&&CL.tok&&CL.me&&CL.me.role==='new'&&typeof window.authWizard==='function'&&!document.getElementById('wzOn'))window.authWizard();
}

patchLogin();
handleHash();window.addEventListener("hashchange",handleHash);
if(CL.me)vRender();
})();
