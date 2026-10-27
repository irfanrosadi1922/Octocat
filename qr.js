/* QR encoder ringkas: mode byte, koreksi galat M, versi 1-20 (hingga 666 byte). Tanpa dependensi. */
function qrMatrix(text){
  const bytes=Array.from(new TextEncoder().encode(String(text)));
  const ECC=[0,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26],NB=[0,1,1,1,2,2,4,4,4,5,5,5,8,9,9,10,10,11,13,14,16];
  const raw=v=>{let r=(16*v+128)*v+64;if(v>=2){const a=Math.floor(v/7)+2;r-=(25*a-10)*a-55;if(v>=7)r-=36}return r};
  let ver=0,dcw=0;
  for(let v=1;v<=20;v++){
    const d=Math.floor(raw(v)/8)-ECC[v]*NB[v];
    if(4+(v<10?8:16)+8*bytes.length<=d*8){ver=v;dcw=d;break}
  }
  if(!ver)throw new Error('Teks terlalu panjang untuk QR');
  const bits=[],put=(val,n)=>{for(let i=n-1;i>=0;i--)bits.push((val>>>i)&1)};
  put(4,4);put(bytes.length,ver<10?8:16);bytes.forEach(b=>put(b,8));
  put(0,Math.min(4,dcw*8-bits.length));
  while(bits.length%8)bits.push(0);
  for(let p=0xEC;bits.length<dcw*8;p^=0xEC^0x11)put(p,8);
  const data=[];for(let i=0;i<bits.length;i+=8){let b=0;for(let j=0;j<8;j++)b=b<<1|bits[i+j];data.push(b)}
  /* Reed-Solomon */
  const mul=(x,y)=>{let z=0;for(let i=7;i>=0;i--){z=(z<<1)^((z>>>7)*0x11D);z^=((y>>>i)&1)*x}return z};
  const divisor=n=>{const r=new Array(n).fill(0);r[n-1]=1;let root=1;for(let i=0;i<n;i++){for(let j=0;j<n;j++){r[j]=mul(r[j],root);if(j+1<n)r[j]^=r[j+1]}root=mul(root,2)}return r};
  const remainder=(d,div)=>{const r=new Array(div.length).fill(0);for(const b of d){const f=b^r.shift();r.push(0);div.forEach((c,i)=>{r[i]^=mul(c,f)})}return r};
  const nb=NB[ver],el=ECC[ver],rc=Math.floor(raw(ver)/8),ns=nb-rc%nb,sl=Math.floor(rc/nb),div=divisor(el),blocks=[];
  for(let i=0,k=0;i<nb;i++){
    const dat=data.slice(k,k+sl-el+(i<ns?0:1));k+=dat.length;
    const ecc=remainder(dat,div);if(i<ns)dat.push(0);blocks.push(dat.concat(ecc));
  }
  const all=[];
  for(let i=0;i<blocks[0].length;i++)blocks.forEach((b,j)=>{if(i!==sl-el||j>=ns)all.push(b[i])});
  /* matriks */
  const n=ver*4+17,M=Array.from({length:n},()=>new Array(n).fill(false)),F=Array.from({length:n},()=>new Array(n).fill(false));
  const set=(x,y,d)=>{M[y][x]=d;F[y][x]=true};
  for(let i=0;i<n;i++){set(6,i,i%2===0);set(i,6,i%2===0)}
  const finder=(x,y)=>{for(let dy=-4;dy<=4;dy++)for(let dx=-4;dx<=4;dx++){const d=Math.max(Math.abs(dx),Math.abs(dy)),xx=x+dx,yy=y+dy;if(xx>=0&&xx<n&&yy>=0&&yy<n)set(xx,yy,d!==2&&d!==4)}};
  finder(3,3);finder(n-4,3);finder(3,n-4);
  if(ver>1){
    const na=Math.floor(ver/7)+2,step=Math.ceil((ver*4+4)/(na*2-2))*2,pos=[6];
    for(let p=n-7;pos.length<na;p-=step)pos.splice(1,0,p);
    for(let i=0;i<na;i++)for(let j=0;j<na;j++){
      if((i===0&&j===0)||(i===0&&j===na-1)||(i===na-1&&j===0))continue;
      for(let dy=-2;dy<=2;dy++)for(let dx=-2;dx<=2;dx++)set(pos[i]+dx,pos[j]+dy,Math.max(Math.abs(dx),Math.abs(dy))!==1);
    }
  }
  const bit=(x,i)=>((x>>>i)&1)!==0;
  const fmt=mask=>{
    const d=0<<3|mask;let r=d;for(let i=0;i<10;i++)r=(r<<1)^((r>>>9)*0x537);
    const b=(d<<10|r)^0x5412;
    for(let i=0;i<=5;i++)set(8,i,bit(b,i));
    set(8,7,bit(b,6));set(8,8,bit(b,7));set(7,8,bit(b,8));
    for(let i=9;i<15;i++)set(14-i,8,bit(b,i));
    for(let i=0;i<8;i++)set(n-1-i,8,bit(b,i));
    for(let i=8;i<15;i++)set(8,n-15+i,bit(b,i));
    set(8,n-8,true);
  };
  fmt(0);
  if(ver>=7){
    let r=ver;for(let i=0;i<12;i++)r=(r<<1)^((r>>>11)*0x1F25);
    const b=ver<<12|r;
    for(let i=0;i<18;i++){const a=n-11+i%3,c=Math.floor(i/3);set(a,c,bit(b,i));set(c,a,bit(b,i))}
  }
  /* isi data zig-zag */
  let k=0;
  for(let right=n-1;right>=1;right-=2){
    if(right===6)right=5;
    for(let v=0;v<n;v++)for(let j=0;j<2;j++){
      const x=right-j,up=((right+1)&2)===0,y=up?n-1-v:v;
      if(!F[y][x]&&k<all.length*8){M[y][x]=bit(all[k>>>3],7-(k&7));k++}
    }
  }
  const mask=m=>{for(let y=0;y<n;y++)for(let x=0;x<n;x++){
    let inv;
    switch(m){case 0:inv=(x+y)%2===0;break;case 1:inv=y%2===0;break;case 2:inv=x%3===0;break;case 3:inv=(x+y)%3===0;break;
      case 4:inv=(Math.floor(x/3)+Math.floor(y/2))%2===0;break;case 5:inv=x*y%2+x*y%3===0;break;
      case 6:inv=(x*y%2+x*y%3)%2===0;break;default:inv=((x+y)%2+x*y%3)%2===0}
    if(!F[y][x]&&inv)M[y][x]=!M[y][x];
  }};
  const penalty=()=>{
    let s=0;
    const line=g=>{ // runs + pola mirip finder
      let run=1;
      for(let i=1;i<n;i++){if(g(i)===g(i-1)){run++;if(run===5)s+=3;else if(run>5)s++}else run=1}
      for(let i=0;i+10<n+0;i++){
        const a=[1,0,1,1,1,0,1,0,0,0,0],b=[0,0,0,0,1,0,1,1,1,0,1];
        let ma=true,mb=true;for(let j=0;j<11;j++){const v=g(i+j)?1:0;if(v!==a[j])ma=false;if(v!==b[j])mb=false}
        if(ma)s+=40;if(mb)s+=40;
      }
    };
    for(let y=0;y<n;y++)line(i=>M[y][i]);
    for(let x=0;x<n;x++)line(i=>M[i][x]);
    for(let y=0;y<n-1;y++)for(let x=0;x<n-1;x++){const c=M[y][x];if(c===M[y][x+1]&&c===M[y+1][x]&&c===M[y+1][x+1])s+=3}
    let dark=0;for(const r of M)for(const c of r)if(c)dark++;
    s+=(Math.ceil(Math.abs(dark*20-n*n*10)/(n*n))-1)*10;
    return s;
  };
  let best=0,bp=1e9;
  for(let m=0;m<8;m++){mask(m);fmt(m);const p=penalty();if(p<bp){bp=p;best=m}mask(m)}
  mask(best);fmt(best);
  return M;
}
function qrSvg(text,px){
  const M=qrMatrix(text),n=M.length,q=4;let d='';
  for(let y=0;y<n;y++)for(let x=0;x<n;x++)if(M[y][x])d+='M'+(x+q)+' '+(y+q)+'h1v1h-1z';
  return`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n+q*2} ${n+q*2}" width="${px||240}" height="${px||240}" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path d="${d}" fill="#000"/></svg>`;
}

/* PNG dari QR (untuk "Simpan QR") */
function qrPng(text,px){
  const M=qrMatrix(text),n=M.length,q=4,sc=Math.max(2,Math.floor((px||720)/(n+q*2))),W=(n+q*2)*sc,c=document.createElement('canvas');
  c.width=c.height=W;const g=c.getContext('2d');g.fillStyle='#fff';g.fillRect(0,0,W,W);g.fillStyle='#000';
  for(let y=0;y<n;y++)for(let x=0;x<n;x++)if(M[y][x])g.fillRect((x+q)*sc,(y+q)*sc,sc,sc);
  return c.toDataURL('image/png');
}

/* ---------- QRIS (Indonesia): ubah QRIS statis milik toko menjadi QRIS dinamis berisi nominal ---------- */
function qrisCrc(s){let c=0xFFFF;for(let i=0;i<s.length;i++){c^=s.charCodeAt(i)<<8;for(let j=0;j<8;j++)c=(c&0x8000)?((c<<1)^0x1021)&0xFFFF:(c<<1)&0xFFFF}return c.toString(16).toUpperCase().padStart(4,'0')}
function qrisParse(s){
  const out=[];let i=0;
  while(i<s.length){
    if(i+4>s.length)return null;
    const t=s.substr(i,2),l=s.substr(i+2,2);
    if(!/^\d\d$/.test(t)||!/^\d\d$/.test(l))return null;
    const n=+l;if(i+4+n>s.length)return null;
    out.push({t,v:s.substr(i+4,n)});i+=4+n;
  }
  return out;
}
/* periksa teks QRIS hasil pindai: {ok,s,name,city,err} */
function qrisCheck(raw){
  const s=String(raw==null?'':raw).replace(/[\r\n\t]/g,'').trim();
  if(!s)return{ok:false,err:'Teks QRIS masih kosong'};
  if(/^https?:\/\//i.test(s))return{ok:false,err:'Ini tautan, bukan teks QRIS. Pindai QRIS toko dengan aplikasi pemindai QR lalu salin teks yang diawali 000201'};
  if(!s.startsWith('000201'))return{ok:false,err:'Teks QRIS harus diawali 000201'};
  if(s.length>700)return{ok:false,err:'Teks QRIS terlalu panjang'};
  const T=qrisParse(s);
  if(!T||!T.length)return{ok:false,err:'Format QRIS tidak terbaca (teks terpotong atau ada karakter lain)'};
  const last=T[T.length-1];
  if(last.t!=='63'||last.v.length!==4)return{ok:false,err:'Teks QRIS tidak lengkap (kode pengaman di ujung hilang)'};
  if(qrisCrc(s.slice(0,-4))!==last.v.toUpperCase())return{ok:false,err:'Kode pengaman QRIS tidak cocok: teks kemungkinan terpotong atau salah salin'};
  const g=t=>{const x=T.find(y=>y.t===t);return x?x.v:''};
  if(g('58')!=='ID')return{ok:false,err:'Ini bukan QRIS Indonesia (kode negara harus ID)'};
  if(g('53')&&g('53')!=='360')return{ok:false,err:'Mata uang QRIS harus rupiah (360)'};
  if(!T.some(x=>+x.t>=26&&+x.t<=51))return{ok:false,err:'Data pedagang tidak ditemukan di QRIS'};
  return{ok:true,s,name:g('59'),city:g('60')};
}
/* QRIS dinamis: titik inisiasi 11 -> 12, sisipkan nominal (tag 54), hitung ulang CRC16 */
function qrisDynamic(raw,amount){
  const c=qrisCheck(raw);if(!c.ok)throw new Error(c.err);
  const a=Math.round(Number(amount)*100)/100;
  if(!(a>0)||a>9999999999)throw new Error('Nominal tidak valid');
  const as=Number.isInteger(a)?String(a):a.toFixed(2).replace(/0+$/,'');
  const items=qrisParse(c.s).filter(x=>x.t!=='54'&&x.t!=='63');
  items.forEach(x=>{if(x.t==='01')x.v='12'});
  const at=items.findIndex(x=>+x.t>54);
  items.splice(at<0?items.length:at,0,{t:'54',v:as});
  const body=items.map(x=>x.t+String(x.v.length).padStart(2,'0')+x.v).join('')+'6304';
  return body+qrisCrc(body);
}
