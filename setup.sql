-- =====================================================================
--  Ordela — database Supabase (jalankan SEKALI di Supabase > SQL Editor)
--  Aman dijalankan ulang (memperbarui fungsi, data tidak dihapus).
--  Semua tabel ada di skema "pos" yang TIDAK terbuka untuk internet.
--  Satu-satunya pintu masuk: fungsi public.pos_api(p jsonb).
-- =====================================================================
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists pos;

-- ---- multi-toko: tabel data diganti nama menjadi pos.t_* dan diberi VIEW bernama lama yang otomatis hanya menampilkan
-- data toko milik sesi (pos.sid()). Seluruh fungsi di bawah memakai nama lama, jadi tak bisa melihat data toko lain.
do $$ declare f text; t text; sigs text[];
begin
  -- daftar tanda tangan fungsi diambil SEKALIGUS di awal: drop ... cascade bisa ikut menghapus fungsi lain,
  -- dan oid yang sudah hilang tercetak sebagai angka (membuat setup.sql gagal saat dijalankan ulang)
  select coalesce(array_agg(p.oid::regprocedure::text), '{}') into sigs from pg_proc p where p.pronamespace = 'pos'::regnamespace;
  foreach f in array sigs loop
    execute 'drop function if exists ' || f || ' cascade';
  end loop;
  foreach t in array array['users', 'audit', 'doc', 'snapshots', 'co', 'att', 'meta', 'push_tokens'] loop
    if to_regclass('pos.' || t) is not null and to_regclass('pos.t_' || t) is null
       and (select c.relkind from pg_class c where c.oid = to_regclass('pos.' || t)) = 'r' then
      execute format('alter table pos.%I rename to %I', t, 't_' || t);
    end if;
  end loop;
end $$;

create table if not exists pos.t_users(
  id bigint generated always as identity primary key,
  username text not null unique,
  name text not null,
  role text not null check (role in ('owner','staff')),
  perms jsonb not null default '[]',
  pw text not null,                       -- bcrypt (pgcrypto), bukan sandi asli
  active boolean not null default true,
  last_login timestamptz,
  created_at timestamptz not null default now());
create table if not exists pos.sessions(
  th text primary key,                    -- sha256 dari token; token asli tidak disimpan
  uid bigint not null references pos.t_users(id) on delete cascade,
  exp timestamptz not null);
alter table pos.t_users add column if not exists email text not null default '';
alter table pos.t_users add column if not exists phone text not null default '';
alter table pos.t_users add column if not exists photo text not null default '';
alter table pos.t_users add column if not exists single boolean;            -- null = otomatis (karyawan: ya, owner: tidak)
alter table pos.sessions add column if not exists seen_at timestamptz not null default now();   -- terakhir dipakai; sesi mati bila 12 jam tidak ada permintaan
alter table pos.sessions add column if not exists kicked_at timestamptz;   -- diisi saat perangkat ini dikeluarkan karena login di perangkat lain
create index if not exists sessions_uid on pos.sessions(uid);
-- ---- pendaftaran mandiri (Supabase Auth): kolom tambahan, peran 'new' = sudah daftar tetapi belum punya toko
alter table pos.t_users add column if not exists auth_id uuid;                 -- akun di auth.users (email + sandi dikelola Supabase Auth)
alter table pos.t_users add column if not exists birth date;
alter table pos.t_users add column if not exists address text not null default '';
do $$ begin
  alter table pos.t_users drop constraint if exists users_role_check;
  alter table pos.t_users drop constraint if exists t_users_role_check;
  alter table pos.t_users add constraint users_role_check check (role = 'new' or length(btrim(role)) between 1 and 32);
end $$;
create unique index if not exists users_auth_id_u on pos.t_users(auth_id) where auth_id is not null;
do $$ begin
  create unique index if not exists users_email_u on pos.t_users(lower(email)) where email <> '';
exception when others then raise notice 'users_email_u dilewati: ada email ganda di data lama';
end $$;
create table if not exists pos.t_audit(
  id bigint generated always as identity primary key,
  t timestamptz not null default now(), uid bigint, uname text not null default '',
  action text not null, detail text not null default '');
create table if not exists pos.t_doc(
  id int primary key check (id = 1), json jsonb, version int not null default 0, updated_at timestamptz);
create table if not exists pos.t_snapshots(
  day date primary key, json jsonb not null, version int not null, created_at timestamptz not null default now());
create table if not exists pos.t_co(
  id bigint generated always as identity primary key,
  tok text not null unique, idem text unique, day date not null, num text not null,
  name text not null, tbl text not null default '', type text not null, note text not null default '',
  lines jsonb not null, sub numeric not null, tax numeric not null, total numeric not null,
  status text not null default 'new', printed int not null default 0, claim_at bigint,
  sale_no text, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
alter table pos.t_co add column if not exists pay text not null default '';
alter table pos.t_co add column if not exists pst int not null default 0;
alter table pos.t_co add column if not exists proof text not null default '';
create index if not exists co_day on pos.t_co(day);
create index if not exists co_status on pos.t_co(status, id);
create table if not exists pos.t_att(
  id bigint generated always as identity primary key,
  uid bigint not null, uname text not null default '', name text not null default '',
  day date not null, ts timestamptz not null default now(), type text not null,
  shift_id text not null default '', shift_name text not null default '', sstart text not null default '', send text not null default '',
  status text not null default 'none', mins int not null default 0,
  lat double precision, lng double precision, acc int, dist int, photo text not null default '');
create index if not exists att_uid on pos.t_att(uid, id);
create index if not exists att_day on pos.t_att(day);
create table if not exists pos.t_meta(k text primary key, v jsonb not null);
create table if not exists pos.t_push_tokens(tok text primary key, uid bigint not null, created_at timestamptz not null default now());
create table if not exists pos.fails(ip text primary key, n int not null default 0, until timestamptz);
create table if not exists pos.hits(id bigint generated always as identity primary key, ip text not null, t timestamptz not null default now());
create table if not exists pos.rl(id bigint generated always as identity primary key, k text not null, ip text not null, t timestamptz not null default now());
create index if not exists rl_k on pos.rl(k, ip, t);
alter table pos.rl enable row level security;
create index if not exists hits_ip on pos.hits(ip, t);


-- ================================================================ multi-toko
create table if not exists pos.stores(
  id bigint generated always as identity primary key,
  code text not null unique,                 -- kode publik toko (untuk tautan/QR pemesanan online)
  name text not null, owner_id bigint, created_at timestamptz not null default now());
alter table pos.stores enable row level security;
alter table pos.t_users add column if not exists store_id bigint references pos.stores(id);
alter table pos.t_audit add column if not exists store_id bigint;
alter table pos.t_doc add column if not exists store_id bigint;
alter table pos.t_snapshots add column if not exists store_id bigint;
alter table pos.t_co add column if not exists store_id bigint;
alter table pos.t_att add column if not exists store_id bigint;
alter table pos.t_meta add column if not exists store_id bigint;
alter table pos.t_push_tokens add column if not exists store_id bigint;
create index if not exists users_store on pos.t_users(store_id);
create index if not exists co_store on pos.t_co(store_id, day);
create index if not exists att_store on pos.t_att(store_id);
create index if not exists audit_store on pos.t_audit(store_id, id);

-- data lama (satu toko) -> toko nomor 1, dimiliki owner pertama
do $$ declare v_owner bigint; v_name text; v_code text;
begin
  if not exists (select 1 from pos.stores) and exists (select 1 from pos.t_users where role in ('owner', 'staff')) then
    select id into v_owner from pos.t_users where role = 'owner' order by id limit 1;
    select coalesce(nullif(json #>> '{set,store}', ''), 'Ordela') into v_name from pos.t_doc limit 1;
    v_code := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    insert into pos.stores(id, code, name, owner_id) overriding system value values (1, v_code, coalesce(v_name, 'Ordela'), v_owner);
    perform setval(pg_get_serial_sequence('pos.stores', 'id'), 1);
    update pos.t_users set store_id = 1 where store_id is null and role in ('owner', 'staff');
    update pos.t_audit set store_id = 1 where store_id is null;
    update pos.t_doc set store_id = 1 where store_id is null;
    update pos.t_snapshots set store_id = 1 where store_id is null;
    update pos.t_co set store_id = 1 where store_id is null;
    update pos.t_att set store_id = 1 where store_id is null;
    update pos.t_meta set store_id = 1 where store_id is null and k <> 'push';
    update pos.t_meta set store_id = 0 where store_id is null and k = 'push';   -- konfigurasi notifikasi APK berlaku untuk semua toko
    update pos.t_push_tokens set store_id = 1 where store_id is null;
    insert into pos.t_doc(store_id, id, json, version) select 1, 1, null, 0 where not exists (select 1 from pos.t_doc where store_id = 1);
    insert into pos.t_meta(store_id, k, v) select 1, 'rev', to_jsonb((extract(epoch from now()) * 1000)::bigint) where not exists (select 1 from pos.t_meta where store_id = 1 and k = 'rev');
  end if;
end $$;

-- kunci unik per toko (menggantikan kunci utama lama)
do $$ declare t text; c text;
begin
  foreach t in array array['doc', 'snapshots', 'meta'] loop
    select conname into c from pg_constraint where conrelid = ('pos.t_' || t)::regclass and contype = 'p';
    if c is not null then execute format('alter table pos.t_%I drop constraint %I', t, c); end if;
  end loop;
end $$;
create unique index if not exists doc_sid on pos.t_doc(store_id, id);
create unique index if not exists snap_sid on pos.t_snapshots(store_id, day);
create unique index if not exists meta_sid on pos.t_meta(store_id, k);

create or replace function pos.sid() returns bigint language sql stable as
$$ select nullif(current_setting('pos.sid', true), '')::bigint $$;

create or replace view pos.users as select * from pos.t_users where store_id = pos.sid();
create or replace view pos.audit as select * from pos.t_audit where store_id = pos.sid();
create or replace view pos.doc as select * from pos.t_doc where store_id = pos.sid();
create or replace view pos.snapshots as select * from pos.t_snapshots where store_id = pos.sid();
create or replace view pos.co as select * from pos.t_co where store_id = pos.sid();
create or replace view pos.att as select * from pos.t_att where store_id = pos.sid();
create or replace view pos.meta as select * from pos.t_meta where store_id = pos.sid();
create or replace view pos.push_tokens as select * from pos.t_push_tokens where store_id = pos.sid();
alter view pos.users alter column store_id set default pos.sid();
alter view pos.audit alter column store_id set default pos.sid();
alter view pos.doc alter column store_id set default pos.sid();
alter view pos.snapshots alter column store_id set default pos.sid();
alter view pos.co alter column store_id set default pos.sid();
alter view pos.att alter column store_id set default pos.sid();
alter view pos.meta alter column store_id set default pos.sid();
alter view pos.push_tokens alter column store_id set default pos.sid();

alter table pos.t_users enable row level security;  alter table pos.sessions enable row level security;
alter table pos.t_audit enable row level security;  alter table pos.t_doc enable row level security;
alter table pos.t_snapshots enable row level security; alter table pos.t_co enable row level security;
alter table pos.t_meta enable row level security;   alter table pos.fails enable row level security;
alter table pos.hits enable row level security;  alter table pos.t_att enable row level security;
alter table pos.t_push_tokens enable row level security;

-- ---------------------------------------------------------------- pembantu
create or replace function pos.r(s int, b jsonb) returns jsonb language sql immutable as
$$ select jsonb_build_object('s', s, 'b', b) $$;

create or replace function pos.num(j jsonb) returns numeric language sql immutable as $$
  select case jsonb_typeof(j)
    when 'number' then (j #>> '{}')::numeric
    when 'string' then case when (j #>> '{}') ~ '^\s*-?\d{1,15}(\.\d{1,8})?\s*$' then btrim(j #>> '{}')::numeric else 0 end
    when 'boolean' then case when j = 'true'::jsonb then 1 else 0 end
    else 0 end $$;

create or replace function pos.clean(t text, n int) returns text language sql immutable as
$$ select left(btrim(regexp_replace(regexp_replace(coalesce(t, ''), '[[:cntrl:]]+', ' ', 'g'), '\s+', ' ', 'g')), n) $$;

create or replace function pos.rate(p_k text, p_lim int, p_win interval) returns boolean language plpgsql as $$
declare v_ip text := pos.client_ip();
begin
  if random() < 0.05 then delete from pos.rl where t < now() - interval '1 day'; end if;
  if (select count(*) from pos.rl where rl.k = p_k and rl.ip = v_ip and rl.t > now() - p_win) >= p_lim then return false; end if;
  insert into pos.rl(k, ip) values (p_k, v_ip);
  return true;
end $$;

create or replace function pos.iso(ts timestamptz) returns text language sql immutable as
$$ select to_char(ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;

create or replace function pos.tz() returns text language sql stable as
$$ select coalesce((select v #>> '{}' from pos.meta where k = 'tz'), 'Asia/Jakarta') $$;

create or replace function pos.bump() returns void language sql as
$$ update pos.meta set v = to_jsonb(((v #>> '{}')::numeric + 1)::bigint) where k = 'rev' $$;

create or replace function pos.rev() returns bigint language sql stable as
$$ select (v #>> '{}')::bigint from pos.meta where k = 'rev' $$;

create or replace function pos.audit(uid bigint, uname text, act text, det text) returns void language plpgsql as $$
begin
  insert into pos.audit(uid, uname, action, detail) values (uid, coalesce(uname, ''), act, left(coalesce(det, ''), 300));
  if random() < 0.02 then delete from pos.audit where id < (select max(id) - 2000 from pos.audit); end if;
end $$;

create or replace function pos.client_ip() returns text language plpgsql stable as $$
declare h jsonb; v text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::jsonb; exception when others then h := null; end;
  v := nullif(btrim(coalesce(h ->> 'cf-connecting-ip', '')), '');
  if v is null then v := nullif(btrim(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1)), ''); end if;
  return coalesce(v, '?');
end $$;

create or replace function pos.clean_perms(j jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (
    select x, min(o) o from jsonb_array_elements_text(case when jsonb_typeof(j) = 'array' then j else '[]'::jsonb end) with ordinality t(x, o)
    where x in ('co','inv','hist','prn','set','att') group by x) s $$;

create or replace function pos.perms_of(u pos.users) returns jsonb language sql immutable as
$$ select case when u.role = 'owner' then '["co","inv","hist","prn","set","att"]'::jsonb else pos.clean_perms(u.perms) end $$;

create or replace function pos.can(u pos.users, k text) returns boolean language sql immutable as
$$ select u.role = 'owner' or pos.perms_of(u) ? k $$;

create or replace function pos.me_view(u pos.users) returns jsonb language sql stable as $$
  select jsonb_build_object('id', u.id, 'username', u.username, 'name', u.name, 'role', u.role, 'perms', pos.perms_of(u),
    'single', coalesce(u.single, u.role <> 'owner'), 'active', u.active, 'lastLogin', coalesce(pos.iso(u.last_login), ''), 'createdAt', pos.iso(u.created_at),
    'email', u.email, 'phone', u.phone, 'hasPhoto', u.photo <> '') $$;
create or replace function pos.me_self(u pos.users) returns jsonb language sql stable as $$
  select pos.me_view(u) || jsonb_build_object('photo', u.photo, 'birth', coalesce(u.birth::text, ''), 'address', u.address,
    'hasAuth', u.auth_id is not null, 'store', (select jsonb_build_object('code', s.code, 'name', s.name) from pos.stores s where s.id = u.store_id),
    'emailVerified', coalesce((select a.email_confirmed_at is not null from auth.users a where a.id = u.auth_id), false),
    'pendingEmail', coalesce((select nullif(lower(a.email_change), '') from auth.users a where a.id = u.auth_id), '')) $$;

-- ---- sandi: akun Supabase Auth memakai hash di auth.users, akun lama (dan staf) memakai pos.users.pw
create or replace function pos.pw_ok(u pos.users, pw text) returns boolean language plpgsql as $$
declare h text;
begin
  if pw is null or u.id is null then return false; end if;
  if u.auth_id is not null then
    select encrypted_password into h from auth.users where id = u.auth_id;
    return h is not null and h <> '' and h = extensions.crypt(pw, h);
  end if;
  return u.pw <> '!' and u.pw = extensions.crypt(pw, u.pw);
end $$;
create or replace function pos.pw_set(uid bigint, pw text) returns void language plpgsql as $$
declare v_auth uuid; h text := extensions.crypt(pw, extensions.gen_salt('bf', 10));
begin
  select auth_id into v_auth from pos.t_users where id = uid;
  if v_auth is not null then update auth.users set encrypted_password = h, updated_at = now() where id = v_auth;
  else update pos.t_users set pw = h where id = uid; end if;
end $$;

-- ---- akun baru dari Supabase Auth -> baris pos.users (peran 'new' sampai toko disiapkan)
create or replace function pos.on_auth_user() returns trigger language plpgsql security definer set search_path = '' as $$
declare md jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb); un text; v_birth date; nm text;
begin
  if md ->> 'kind' = 'link' then return new; end if;
  un := lower(btrim(coalesce(md ->> 'username', '')));
  if un !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then raise exception 'Username tidak valid'; end if;
  if exists (select 1 from pos.t_users where username = un) then raise exception 'Username sudah dipakai'; end if;
  begin v_birth := nullif(md ->> 'birth', '')::date; exception when others then v_birth := null; end;
  nm := coalesce(nullif(regexp_replace(btrim(coalesce(md ->> 'name', '')), '\s+', ' ', 'g'), ''), un);
  insert into pos.t_users(username, name, role, perms, pw, auth_id, email, phone, birth, address)
  values (un, left(nm, 60), 'new', '[]'::jsonb, '!', new.id, lower(coalesce(new.email, '')), left(coalesce(md ->> 'phone', ''), 20),
          v_birth, left(coalesce(md ->> 'address', ''), 300));
  return new;
end $$;
create or replace function pos.on_auth_pw() returns trigger language plpgsql security definer set search_path = '' as $$
begin  -- sandi diganti (reset lewat email / ganti sandi): semua sesi aplikasi akun itu dicabut
  if new.encrypted_password is distinct from old.encrypted_password then
    delete from pos.sessions where uid in (select id from pos.t_users where auth_id = new.id);
  end if;
  return new;
end $$;
do $$ begin
  drop trigger if exists pos_on_auth_pw on auth.users;
  create trigger pos_on_auth_pw after update of encrypted_password on auth.users for each row execute function pos.on_auth_pw();
exception when others then raise notice 'trigger sandi auth.users gagal dibuat: %', sqlerrm;
end $$;
do $$ begin
  drop trigger if exists pos_on_auth_user on auth.users;
  create trigger pos_on_auth_user after insert on auth.users for each row execute function pos.on_auth_user();
exception when others then raise notice 'trigger auth.users gagal dibuat: %', sqlerrm;
end $$;

create or replace function pos.on_auth_email() returns trigger language plpgsql security definer set search_path = '' as $$
begin  -- email baru sudah diverifikasi di Supabase Auth: samakan di data aplikasi (dipakai untuk login lewat email)
  if new.email is distinct from old.email and coalesce(new.email, '') <> '' then
    update pos.t_users set email = lower(new.email) where auth_id = new.id;
  end if;
  return new;
exception when unique_violation then
  raise notice 'email % dipakai akun lain di pos.users', new.email;
  return new;
end $$;
do $$ begin
  drop trigger if exists pos_on_auth_email on auth.users;
  create trigger pos_on_auth_email after update of email on auth.users for each row execute function pos.on_auth_email();
exception when others then raise notice 'trigger email auth.users gagal dibuat: %', sqlerrm;
end $$;

create or replace function pos.auth(tok text) returns pos.users language plpgsql as $$
declare u pos.users; h text;
begin
  if tok is null or length(tok) < 20 or length(tok) > 200 then return null; end if;
  h := encode(extensions.digest(tok, 'sha256'), 'hex');
  select us.* into u from pos.sessions s join pos.t_users us on us.id = s.uid
   where s.th = h and s.exp > now() and s.kicked_at is null and s.seen_at > now() - interval '12 hours' and us.active;
  if u.id is not null then update pos.sessions set seen_at = now() where th = h and seen_at < now() - interval '1 minute'; end if;
  return u;
end $$;
create or replace function pos.kicked(tok text) returns boolean language sql stable as $$
  select tok is not null and length(tok) between 20 and 200 and exists (select 1 from pos.sessions s
    where s.th = encode(extensions.digest(tok, 'sha256'), 'hex') and s.exp > now() and s.kicked_at is not null) $$;
create or replace function pos.expired(tok text) returns boolean language sql stable as $$
  select tok is not null and length(tok) between 20 and 200 and exists (select 1 from pos.sessions s
    where s.th = encode(extensions.digest(tok, 'sha256'), 'hex') and s.exp > now() and s.kicked_at is null and s.seen_at <= now() - interval '12 hours') $$;

create or replace function pos.new_session(uid bigint) returns text language plpgsql as $$
declare t text := 'ps' || encode(extensions.gen_random_bytes(24), 'hex');
begin
  insert into pos.sessions(th, uid, exp) values (encode(extensions.digest(t, 'sha256'), 'hex'), uid, now() + interval '14 days');
  if random() < 0.1 then delete from pos.sessions where exp < now() or kicked_at < now() - interval '7 days' or seen_at < now() - interval '3 days'; end if;
  return t;
end $$;

-- ------------------------------------------------------------ pesanan: tampilan
create or replace function pos.staff_view(r pos.co) returns jsonb language sql stable as $$
  select jsonb_build_object('id', r.id, 'num', r.num, 'name', r.name, 'tbl', r.tbl, 'type', r.type, 'note', r.note, 'lines', r.lines,
    'sub', r.sub, 'tax', r.tax, 'total', r.total, 'status', r.status, 'printed', r.printed, 'saleNo', coalesce(r.sale_no, ''), 'pay', r.pay, 'pst', r.pst, 'hp', r.proof <> '',
    't', pos.iso(r.created_at), 'u', pos.iso(r.updated_at)) $$;
create or replace function pos.cust_view(r pos.co) returns jsonb language sql stable as $$
  select jsonb_build_object('num', r.num, 'name', r.name, 'tbl', r.tbl, 'type', r.type, 'note', r.note, 'lines', r.lines,
    'total', r.total, 'sub', r.sub, 'tax', r.tax, 'status', r.status, 'pay', r.pay, 'pst', r.pst, 'hp', r.proof <> '', 't', pos.iso(r.created_at)) $$;
create or replace function pos.co_set() returns jsonb language sql stable as $$
  select jsonb_build_object('on', coalesce((select v ->> 'on' from pos.meta where k = 'co'), 'true') <> 'false',
    'msg', left(coalesce((select v ->> 'msg' from pos.meta where k = 'co'), ''), 200),
    'nt', coalesce((select v -> 'nt' from pos.meta where k = 'co'), '{}'::jsonb)) $$;

-- ------------------------------------------------------------ penjaga tulis (karyawan)
create or replace function pos.additive(a jsonb, b jsonb) returns boolean language plpgsql immutable as $$
declare k text;
begin
  if jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
    for k in select jsonb_object_keys(a) loop
      if not (b ? k) or not coalesce(pos.additive(a -> k, b -> k), false) then return false; end if;
    end loop;
    return true;
  end if;
  return coalesce(a = b, false);
end $$;

create or replace function pos.valid_doc(d jsonb) returns boolean language sql immutable as $$
  select jsonb_typeof(d) = 'object' and jsonb_typeof(d -> 'items') = 'array' and jsonb_typeof(d -> 'orders') = 'array'
     and jsonb_typeof(d -> 'set') = 'object' $$;

create or replace function pos.pub_sid(code text) returns boolean language plpgsql as $$
declare v bigint; c text := lower(btrim(coalesce(code, '')));
begin
  if c = '' then select id into v from pos.stores where id = 1;
  elsif c ~ '^[a-z0-9]{4,16}$' then select id into v from pos.stores where stores.code = c; end if;
  if v is null then return false; end if;
  perform set_config('pos.sid', v::text, true); return true;
end $$;

create or replace function pos.guard(me pos.users, cur jsonb, nxt jsonb) returns text language plpgsql as $$
declare pm jsonb; k text; c jsonb; n jsonb; ci int; ni int; cs jsonb; ns jsonb; a int;
begin
  if me.role = 'owner' then return null; end if;
  if cur is null then return 'Hanya owner yang boleh menyiapkan data awal'; end if;
  pm := pos.perms_of(me);
  -- akun yang HANYA punya izin Absensi tidak boleh membuat transaksi atau mengubah stok
  if jsonb_array_length(pm) > 0 and pm <@ '["att"]'::jsonb
     and ((cur -> 'orders') is distinct from (nxt -> 'orders') or (cur -> 'items') is distinct from (nxt -> 'items')) then
    return 'Akun ini hanya punya izin Absensi dan tidak bisa membuat transaksi';
  end if;
  if exists (select o ->> 'no', o from jsonb_array_elements(coalesce(cur -> 'orders', '[]')) o
             except select x ->> 'no', x from jsonb_array_elements(coalesce(nxt -> 'orders', '[]')) x) then
    return 'Riwayat penjualan hanya bisa ditambah, tidak boleh diubah atau dihapus (khusus owner)';
  end if;
  -- karyawan (izin Inventori pun) hanya boleh mengubah stok; menu, harga, modal, kategori khusus owner
  select count(distinct i ->> 'id') into ci from jsonb_array_elements(cur -> 'items') i;
  select count(distinct i ->> 'id') into ni from jsonb_array_elements(nxt -> 'items') i;
  if ci <> ni then return 'Hanya owner yang boleh menambah/menghapus menu'; end if;
  for c in select i from jsonb_array_elements(cur -> 'items') i loop
    n := null;
    select x into n from jsonb_array_elements(nxt -> 'items') x where x ->> 'id' = c ->> 'id' limit 1;
    if n is null then return 'Hanya owner yang boleh menghapus menu'; end if;
    for k in select jsonb_object_keys(c) loop
      if k <> 'stock' and not coalesce(pos.additive(c -> k, n -> k), false) then
        return 'Hanya owner yang boleh mengubah menu/harga: ' || coalesce(c ->> 'name', c ->> 'id');
      end if;
    end loop;
  end loop;
  select coalesce(jsonb_agg(x order by x), '[]') into cs from jsonb_array_elements(coalesce(cur -> 'cats', '[]')) x;
  select coalesce(jsonb_agg(x order by x), '[]') into ns from jsonb_array_elements(coalesce(nxt -> 'cats', '[]')) x;
  if cs <> ns then return 'Hanya owner yang boleh mengubah kategori'; end if;
  -- riwayat stok: catatan baru harus atas nama pengguna itu sendiri, catatan lama tidak boleh dihapus
  select count(*) into a from (select x from jsonb_array_elements(coalesce(nxt -> 'log', '[]')) x
    except select y from jsonb_array_elements(coalesce(cur -> 'log', '[]')) y) t;
  if exists (select 1 from (select x from jsonb_array_elements(coalesce(nxt -> 'log', '[]')) x
      except select y from jsonb_array_elements(coalesce(cur -> 'log', '[]')) y) t
      where coalesce(x ->> 'u', '') <> me.username or jsonb_typeof(x) <> 'object') then
    return 'Catatan riwayat stok harus atas nama Anda. Muat ulang aplikasi bila ini versi lama.';
  end if;
  if exists (select 1 from (select e from jsonb_array_elements(coalesce(cur -> 'log', '[]')) with ordinality c(e, i) where i <= greatest(0, 1000 - a)
      except select x from jsonb_array_elements(coalesce(nxt -> 'log', '[]')) x) t) then
    return 'Riwayat perubahan stok tidak boleh dihapus (khusus owner)';
  end if;
  for k in select jsonb_object_keys(coalesce(cur -> 'set', '{}')) loop
    if (nxt -> 'set') ? k and coalesce(pos.additive(cur -> 'set' -> k, nxt -> 'set' -> k), false) then continue; end if;
    if k in ('gv','lang','fsAuto','logoInit','logoApp') or pm ? 'set' or (k = 'prn' and pm ? 'prn') then continue; end if;
    return 'Anda tidak punya izin mengubah pengaturan (' || k || ')';
  end loop;
  return null;
end $$;

-- ------------------------------------------------------------ menu & pesanan pelanggan
create or replace function pos.qris_ok(q text) returns boolean language sql immutable as $$
  select coalesce(length(q) between 36 and 512 and q ~ '^000201[ -~]+$' and position('5802ID' in q) > 0 and q ~ '6304[0-9A-Fa-f]{4}$', false) $$;

create or replace function pos.pay_cfg(s jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'on', coalesce((s #>> '{pay,on}') = 'true', false) and pos.qris_ok(s #>> '{pay,qris}'),
    'qris', case when pos.qris_ok(s #>> '{pay,qris}') then s #>> '{pay,qris}' else '' end,
    'name', left(coalesce(s #>> '{pay,name}', ''), 60), 'note', left(coalesce(s #>> '{pay,note}', ''), 300)) $$;

create or replace function pos.pub_menu(q jsonb) returns jsonb language plpgsql stable as $$
declare d jsonb; v int; s jsonb; st jsonb := pos.co_set(); items jsonb; ucats text[]; ccats text[]; res text[] := '{}'; x text;
begin
  select json, version into d, v from pos.doc where id = 1;
  if d is null then return pos.r(503, '{"error":"belum siap"}'); end if;
  if q ->> 'since' = v::text then
    return pos.r(200, jsonb_build_object('ver', v, 'unchanged', true, 'open', st -> 'on', 'msg', st -> 'msg'));
  end if;
  s := coalesce(d -> 'set', '{}');
  select coalesce(jsonb_agg(jsonb_build_object('id', i ->> 'id', 'name', coalesce(i ->> 'name', ''), 'cat', coalesce(i ->> 'cat', ''),
      'price', pos.num(i -> 'price'), 'stock', greatest(0, floor(pos.num(i -> 'stock'))),
      'emoji', left(coalesce(nullif(i ->> 'emoji', ''), '🍽️'), 8),
      'img', case when (i ->> 'img') ~ '^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/=]+$' then i ->> 'img' else '' end) order by o), '[]')
    into items from jsonb_array_elements(d -> 'items') with ordinality t(i, o);
  select coalesce(array_agg(c order by o), '{}') into ucats from (select c, min(o) o from
    (select coalesce(i ->> 'cat', '') c, o from jsonb_array_elements(d -> 'items') with ordinality t(i, o)) z group by c) y;
  select coalesce(array_agg(c order by o), '{}') into ccats from jsonb_array_elements_text(case when jsonb_typeof(d -> 'cats') = 'array' then d -> 'cats' else '[]'::jsonb end) with ordinality t(c, o);
  foreach x in array ccats loop if x = any (ucats) then res := res || x; end if; end loop;
  foreach x in array ucats loop if not (x = any (ccats)) then res := res || x; end if; end loop;
  return pos.r(200, jsonb_build_object('ver', v, 'store', coalesce(nullif(s ->> 'store', ''), 'Ordela'),
    'logo', case when (s ->> 'logo') ~ '^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/=]+$' then s ->> 'logo' else 'icon-192.png' end,
    'cur', coalesce(nullif(s ->> 'cur', ''), 'Rp'), 'curPos', case when s ->> 'curPos' = 'after' then 'after' else 'before' end,
    'dec', greatest(0, least(4, pos.num(s -> 'dec'))), 'loc', coalesce(nullif(s ->> 'loc', ''), 'id-ID'),
    'tax', pos.num(s -> 'tax'), 'pay', pos.pay_cfg(s), 'cats', to_jsonb(res), 'items', items, 'open', st -> 'on', 'msg', st -> 'msg'));
end $$;

create or replace function pos.create_order(b jsonb, v_ip text) returns jsonb language plpgsql as $$
declare st jsonb := pos.co_set(); d jsonb; s jsonb; nm text; kk text; ex pos.co; lim int; ids text[] := '{}'; qts int[] := '{}';
  it jsonb; iid text; qty int; ix int; item jsonb; dec int; sub numeric := 0; tx numeric; tot numeric; lines jsonb := '[]'; stock numeric;
  tk text; n int; v_day date; r pos.co; tp text; tx_pct numeric; v_pay text := '';
begin
  perform pg_advisory_xact_lock(7001);
  if not (st ->> 'on')::boolean then return pos.r(403, jsonb_build_object('error', 'closed', 'msg', st -> 'msg')); end if;
  select json into d from pos.doc where id = 1;
  if d is null then return pos.r(503, '{"error":"belum siap"}'); end if;
  if jsonb_typeof(b -> 'website') = 'string' and (b ->> 'website') <> '' then return pos.r(400, '{"error":"ditolak"}'); end if;
  nm := pos.clean(b ->> 'name', 40);
  if nm = '' then return pos.r(400, '{"error":"Nama wajib diisi"}'); end if;
  kk := nullif(pos.clean(b ->> 'key', 64), '');
  if kk is not null then
    select * into ex from pos.co where idem = kk;
    if ex.id is not null then return pos.r(200, jsonb_build_object('tok', ex.tok) || pos.cust_view(ex) || '{"dup":true}'); end if;
  end if;
  lim := greatest(1, coalesce((select (v #>> '{}')::int from pos.meta where meta.k = 'order_rate'), 40));
  delete from pos.hits where t < now() - interval '10 minutes';
  if (select count(*) from pos.hits where hits.ip = v_ip) >= lim then
    return pos.r(429, '{"error":"Terlalu banyak pesanan. Coba lagi beberapa menit lagi."}');
  end if;
  insert into pos.hits(ip) values (v_ip);
  if (select count(*) from pos.co where status = 'new') >= 300 then return pos.r(429, '{"error":"Antrean penuh, mohon panggil pelayan."}'); end if;
  if jsonb_typeof(b -> 'items') <> 'array' or jsonb_array_length(b -> 'items') = 0 or jsonb_array_length(b -> 'items') > 60 then
    return pos.r(400, '{"error":"Pesanan kosong"}');
  end if;
  s := coalesce(d -> 'set', '{}'); dec := greatest(0, least(4, pos.num(s -> 'dec')))::int;
  for it in select x from jsonb_array_elements(b -> 'items') x loop
    iid := case when jsonb_typeof(it) = 'object' then it ->> 'id' end;
    qty := floor(case when jsonb_typeof(it) = 'object' then pos.num(it -> 'qty') else 0 end);
    if iid is null or qty < 1 or not exists (select 1 from jsonb_array_elements(d -> 'items') x where x ->> 'id' = iid) then
      return pos.r(400, '{"error":"Item tidak valid"}');
    end if;
    ix := array_position(ids, iid);
    if ix is null then ids := ids || iid; qts := qts || least(99, qty); else qts[ix] := least(99, qts[ix] + qty); end if;
  end loop;
  for ix in 1 .. coalesce(array_length(ids, 1), 0) loop
    select x into item from jsonb_array_elements(d -> 'items') x where x ->> 'id' = ids[ix] limit 1;
    stock := greatest(0, floor(pos.num(item -> 'stock')));
    if stock < qts[ix] then
      return pos.r(409, jsonb_build_object('error', case when stock <= 0 then coalesce(item ->> 'name', '') || ' sudah habis'
        else coalesce(item ->> 'name', '') || ' tinggal ' || stock end, 'id', ids[ix], 'stock', stock));
    end if;
    lines := lines || jsonb_build_array(jsonb_build_object('id', ids[ix], 'name', coalesce(item ->> 'name', ''), 'price', pos.num(item -> 'price'), 'qty', qts[ix]));
    sub := sub + pos.num(item -> 'price') * qts[ix];
  end loop;
  sub := round(sub, dec); tx_pct := pos.num(s -> 'tax');
  tx := round(sub * tx_pct / 100, dec); tot := round(sub + tx, dec);
  v_day := (now() at time zone pos.tz())::date;
  select count(*) + 1 into n from pos.co where co.day = v_day;
  if b ->> 'pay' in ('qris', 'duitnow') then
    if not (pos.pay_cfg(s) ->> 'on')::boolean then return pos.r(400, '{"error":"Pembayaran online sedang tidak tersedia. Silakan bayar di kasir."}'); end if;
    v_pay := 'qris';
  end if;
  tk := encode(extensions.gen_random_bytes(16), 'hex');
  tp := case when b ->> 'type' = 'Dine In' then 'Dine In' else 'Takeaway' end;
  insert into pos.co(tok, idem, day, num, name, tbl, type, note, lines, sub, tax, total, pay)
    values (tk, kk, v_day, '#' || lpad(n::text, 3, '0'), nm, pos.clean(b ->> 'table', 12), tp, pos.clean(b ->> 'note', 200), lines, sub, tx, tot, v_pay)
    returning * into r;
  if random() < 0.05 then delete from pos.co where status in ('done', 'cancelled') and updated_at < now() - interval '30 days'; end if;
  perform pos.push_ev('new', r);
  perform pos.bump();
  return pos.r(200, jsonb_build_object('tok', tk) || pos.cust_view(r));
end $$;

-- ------------------------------------------------------------ login
create or replace function pos.login(b jsonb) returns jsonb language plpgsql as $$
declare v_ip text := pos.client_ip(); lu timestamptz; un text; u pos.users; pw text; good boolean := false; v_out int;
begin
  select until into lu from pos.fails where ip = v_ip;
  if lu is not null and lu > now() then return pos.r(429, '{"error":"terlalu banyak percobaan"}'); end if;
  un := lower(btrim(coalesce(b ->> 'username', '')));
  pw := case when jsonb_typeof(b -> 'password') = 'string' then b ->> 'password' end;
  if un <> '' and length(un) <= 120 then
    if position('@' in un) > 0 then select * into u from pos.t_users where lower(email) = un and email <> '' order by (auth_id is not null) desc limit 1;
    else select * into u from pos.t_users where username = un; end if;
  end if;
  if u.id is not null and pw is not null and length(pw) <= 200 then good := pos.pw_ok(u, pw);
  else perform extensions.crypt('x', '$2a$10$abcdefghijklmnopqrstuu'); end if;
  if u.id is not null then perform set_config('pos.sid', coalesce(u.store_id, 0)::text, true); end if;
  if not good then
    insert into pos.fails(ip, n) values (v_ip, 1) on conflict (ip) do update set
      n = case when pos.fails.n + 1 >= 8 then 0 else pos.fails.n + 1 end,
      until = case when pos.fails.n + 1 >= 8 then now() + interval '10 minutes' else pos.fails.until end;
    perform pos.audit(null, null, 'login-gagal', left(un, 40) || ' dari ' || v_ip);
    return pos.r(401, '{"error":"username/email atau sandi salah"}');
  end if;
  delete from pos.fails where ip = v_ip;
  if not u.active then return pos.r(403, '{"error":"Akun dinonaktifkan. Hubungi owner."}'); end if;
  update pos.t_users set last_login = now() where id = u.id;
  v_out := 0;
  if coalesce(u.single, u.role <> 'owner') then
    update pos.sessions set kicked_at = now() where uid = u.id and kicked_at is null;
    get diagnostics v_out = row_count;
  end if;
  perform pos.audit(u.id, u.username, 'login', v_ip || case when v_out > 0 then ' (perangkat lama dikeluarkan)' else '' end);
  select * into u from pos.t_users where id = u.id;
  return pos.r(200, jsonb_build_object('token', pos.new_session(u.id), 'days', 14, 'me', pos.me_self(u)));
end $$;

-- ------------------------------------------------------------ router utama

-- ---------------------------------------------------------------- absensi karyawan
create or replace function pos.att_view(a pos.att) returns jsonb language sql immutable as
$$ select jsonb_build_object('id', a.id, 'uid', a.uid, 'uname', a.uname, 'name', a.name, 'day', a.day::text, 't', pos.iso(a.ts), 'type', a.type,
     'shiftId', a.shift_id, 'shift', a.shift_name, 'sstart', a.sstart, 'send', a.send, 'status', a.status, 'mins', a.mins,
     'lat', a.lat, 'lng', a.lng, 'acc', a.acc, 'dist', a.dist, 'hp', a.photo <> '') $$;

create or replace function pos.att_state(v_uid bigint) returns jsonb language plpgsql stable as $$
declare l pos.att; o boolean;
begin
  select * into l from pos.att where uid = v_uid order by id desc limit 1;
  o := l.id is not null and l.type = 'in' and l.ts > now() - interval '18 hours';
  return jsonb_build_object('open', o, 'since', case when o then pos.iso(l.ts) else '' end, 'shiftId', case when o then l.shift_id else '' end,
    'last', case when l.id is null then null else pos.att_view(l) end);
end $$;

create or replace function pos.att_tz(cfg jsonb) returns text language sql stable as $$
  select coalesce((select name from pg_timezone_names where name = cfg ->> 'tz' limit 1), pos.tz()) $$;

create or replace function pos.att_do(me pos.users, b jsonb) returns jsonb language plpgsql as $$
declare cfg jsonb; sh jsonb; sid text; typ text; ph text; la double precision; ln double precision; st jsonb; tzn text; lmin int; d int; grace int;
  v_status text := 'none'; v_mins int := 0; v_dist int; clat double precision; clng double precision; rad int; nr pos.att; nshift int; asg text;
  hh constant text := '^([01][0-9]|2[0-3]):[0-5][0-9]$'; v_day date;
begin
  select coalesce(json #> '{set,att}', '{}'::jsonb) into cfg from pos.doc where id = 1;
  if jsonb_typeof(cfg) <> 'object' or cfg -> 'on' is distinct from 'true'::jsonb then return pos.r(403, '{"error":"Absensi belum diaktifkan oleh owner"}'); end if;
  typ := case b ->> 'type' when 'in' then 'in' when 'out' then 'out' else '' end;
  if typ = '' then return pos.r(400, '{"error":"Jenis absen tidak valid"}'); end if;
  ph := coalesce(b ->> 'photo', '');
  if length(ph) > 160000 or ph !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$' then return pos.r(400, '{"error":"Foto selfie wajib diambil lewat kamera"}'); end if;
  if jsonb_typeof(b -> 'lat') is distinct from 'number' or jsonb_typeof(b -> 'lng') is distinct from 'number' then return pos.r(400, '{"error":"Lokasi GPS wajib diaktifkan"}'); end if;
  la := (b ->> 'lat')::double precision; ln := (b ->> 'lng')::double precision;
  if abs(la) > 90 or abs(ln) > 180 then return pos.r(400, '{"error":"Lokasi GPS wajib diaktifkan"}'); end if;
  st := pos.att_state(me.id);
  if typ = 'in' and (st ->> 'open')::boolean then return pos.r(409, '{"error":"Anda sudah absen masuk. Absen pulang dulu."}'); end if;
  if typ = 'out' and not (st ->> 'open')::boolean then return pos.r(409, '{"error":"Anda belum absen masuk."}'); end if;
  asg := cfg #>> array['assign', me.username];
  sid := case when typ = 'out' then st ->> 'shiftId' else coalesce(nullif(asg, ''), pos.clean(b ->> 'shift', 20)) end;
  select count(*) into nshift from jsonb_array_elements(case when jsonb_typeof(cfg -> 'shifts') = 'array' then cfg -> 'shifts' else '[]'::jsonb end) x
    where coalesce(x ->> 'id', '') <> '' and x ->> 'start' ~ hh and x ->> 'end' ~ hh;
  select x into sh from jsonb_array_elements(case when jsonb_typeof(cfg -> 'shifts') = 'array' then cfg -> 'shifts' else '[]'::jsonb end) x
    where x ->> 'id' = sid and x ->> 'start' ~ hh and x ->> 'end' ~ hh limit 1;
  if typ = 'in' and sh is null and nshift > 0 and coalesce(asg, '') = '' then return pos.r(400, '{"error":"Pilih shift Anda dulu"}'); end if;
  if jsonb_typeof(cfg -> 'lat') = 'number' and jsonb_typeof(cfg -> 'lng') = 'number' then
    clat := (cfg ->> 'lat')::double precision; clng := (cfg ->> 'lng')::double precision;
    rad := least(5000, greatest(20, round(coalesce(pos.num(cfg -> 'radius'), 100))))::int;
    v_dist := round(2 * 6371000 * asin(least(1, sqrt(power(sin(radians(la - clat) / 2), 2) + cos(radians(clat)) * cos(radians(la)) * power(sin(radians(ln - clng) / 2), 2)))))::int;
    if cfg -> 'strict' = 'true'::jsonb and v_dist > rad then
      return pos.r(403, jsonb_build_object('error', 'Anda berada ' || v_dist || ' m dari toko (maksimal ' || rad || ' m). Absen hanya bisa dari toko.'));
    end if;
  end if;
  tzn := pos.att_tz(cfg);
  v_day := (now() at time zone tzn)::date;
  lmin := (extract(hour from (now() at time zone tzn)) * 60 + extract(minute from (now() at time zone tzn)))::int;
  if sh is not null then
    grace := least(120, greatest(0, round(coalesce(pos.num(sh -> 'grace'), 0))))::int;
    if typ = 'in' then
      d := (((lmin - (substr(sh ->> 'start', 1, 2)::int * 60 + substr(sh ->> 'start', 4, 2)::int)) % 1440) + 1440 + 720) % 1440 - 720;
      if d > grace then v_status := 'late'; v_mins := d; else v_status := 'ontime'; end if;
    else
      d := (((lmin - (substr(sh ->> 'end', 1, 2)::int * 60 + substr(sh ->> 'end', 4, 2)::int)) % 1440) + 1440 + 720) % 1440 - 720;
      if d < 0 then v_status := 'early'; v_mins := -d; else v_status := 'ok'; end if;
    end if;
  end if;
  insert into pos.att(uid, uname, name, day, type, shift_id, shift_name, sstart, send, status, mins, lat, lng, acc, dist, photo)
    values (me.id, me.username, me.name, v_day, typ, coalesce(sh ->> 'id', ''), pos.clean(sh ->> 'name', 30), coalesce(sh ->> 'start', ''), coalesce(sh ->> 'end', ''),
      v_status, v_mins, la, ln, round(coalesce(pos.num(b -> 'acc'), 0))::int, v_dist, ph) returning * into nr;
  if random() < 0.05 then
    update pos.att set photo = '' where day < v_day - 60 and photo <> '';
    delete from pos.att where day < v_day - 400;
  end if;
  perform pos.audit(me.id, me.username, case when typ = 'in' then 'absen-masuk' else 'absen-pulang' end,
    coalesce(nullif(nr.shift_name, ''), '-') || ' ' || nr.status || case when nr.mins > 0 then ' ' || nr.mins || 'mnt' else '' end);
  return pos.r(200, jsonb_build_object('rec', pos.att_view(nr) || '{"hp":true}'::jsonb, 'state', pos.att_state(me.id)));
end $$;

create or replace function pos.att_list(me pos.users, q jsonb, own boolean) returns jsonb language plpgsql stable as $$
declare cfg jsonb; tzn text; v_to date; v_from date;
begin
  select coalesce(json #> '{set,att}', '{}'::jsonb) into cfg from pos.doc where id = 1;
  tzn := pos.att_tz(cfg);
  v_to := case when (q ->> 'to') ~ '^\d{4}-\d{2}-\d{2}$' then (q ->> 'to')::date else (now() at time zone tzn)::date end;
  v_from := case when (q ->> 'from') ~ '^\d{4}-\d{2}-\d{2}$' then (q ->> 'from')::date else (now() at time zone tzn)::date - 40 end;
  return pos.r(200, jsonb_build_object('tz', tzn, 'today', ((now() at time zone tzn)::date)::text, 'me', pos.att_state(me.id), 'rows', coalesce((
    select jsonb_agg(pos.att_view(a) order by a.id desc) from (
      select * from pos.att where day between v_from and v_to and (own or uid = me.id) order by id desc limit case when own then 2000 else 500 end) a), '[]')));
end $$;

create or replace function pos.route(m text, u text, q jsonb, b jsonb, t text) returns jsonb language plpgsql as $$
declare me pos.users; v_auth uuid; mt text[]; r pos.co; tu pos.users; own boolean; nrole text; act boolean; nm text; nperms jsonb; un text; nsingle boolean;
  d pos.doc; gerr text; nv int; cnt int; rv bigint; wt numeric; ms bigint; x jsonb; v_proof text;
begin
  if u = '/api/health' then return pos.r(200, '{"ok":true,"pos":true,"sb":true}'); end if;
  if u = '/api/login' and m = 'POST' then return pos.login(b); end if;
  if u = '/api/register/check' and m = 'POST' then
    if not pos.rate('reg', 30, interval '10 minutes') then return pos.r(429, '{"error":"Terlalu banyak percobaan. Coba lagi nanti."}'); end if;
    un := lower(btrim(coalesce(b ->> 'username', '')));
    nm := lower(btrim(coalesce(b ->> 'email', '')));
    return pos.r(200, jsonb_build_object(
      'usernameFree', un ~ '^[a-z0-9][a-z0-9._-]{2,23}$' and not exists (select 1 from pos.t_users where username = un),
      'emailFree', nm = '' or (not exists (select 1 from pos.t_users where lower(email) = nm) and not exists (select 1 from auth.users where lower(email) = nm))));
  end if;
  if u = '/api/public/menu' and m = 'GET' then
    if not pos.pub_sid(q ->> 's') then return pos.r(404, '{"error":"Toko tidak ditemukan"}'); end if;
    return pos.pub_menu(q);
  end if;
  if u = '/api/public/order' and m = 'POST' then
    if not pos.pub_sid(b ->> 's') then return pos.r(404, '{"error":"Toko tidak ditemukan"}'); end if;
    return pos.create_order(b, pos.client_ip());
  end if;
  mt := regexp_match(u, '^/api/public/order/([A-Za-z0-9_-]{10,40})(/cancel|/paid)?$');
  if mt is not null then
    perform set_config('pos.sid', coalesce((select store_id from pos.t_co where tok = mt[1]), 0)::text, true);
    select * into r from pos.co where tok = mt[1];
    if r.id is null then return pos.r(404, '{"error":"tidak ada"}'); end if;
    if mt[2] = '/paid' then
      if m <> 'POST' then return pos.r(405, '{"error":"method"}'); end if;
      if r.pay not in ('qris', 'duitnow') or r.status not in ('new', 'accepted') then return pos.r(409, '{"error":"Pesanan ini tidak bisa dibayar online."}'); end if;
      if r.pst = 2 then return pos.r(200, pos.cust_view(r)); end if;
      v_proof := coalesce(b ->> 'proof', '');
      if v_proof <> '' and (length(v_proof) > 700000 or v_proof !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then
        return pos.r(400, '{"error":"Bukti pembayaran harus berupa foto (JPG/PNG) dan tidak terlalu besar."}');
      end if;
      if v_proof <> '' or r.pst in (0, 3) then
        update pos.co set pst = 1, proof = case when v_proof <> '' then v_proof else proof end, updated_at = now() where id = r.id returning * into r;
        perform pos.bump();
        perform pos.push_ev('pay', r);
      end if;
      return pos.r(200, pos.cust_view(r));
    end if;
    if mt[2] is not null then
      if m <> 'POST' then return pos.r(405, '{"error":"method"}'); end if;
      if r.pst = 2 then return pos.r(409, jsonb_build_object('error', 'Pembayaran sudah dikonfirmasi, hubungi kasir.', 'status', r.status)); end if;
      if r.status <> 'new' then return pos.r(409, jsonb_build_object('error', 'Pesanan sudah diproses, hubungi kasir.', 'status', r.status)); end if;
      update pos.co set status = 'cancelled', updated_at = now() where id = r.id returning * into r;
      perform pos.bump();
      perform pos.push_ev('cancel', r);
      return pos.r(200, pos.cust_view(r));
    end if;
    if m = 'GET' then return pos.r(200, pos.cust_view(r)); end if;
  end if;

  me := pos.auth(t);
  if me.id is null then return pos.r(401, case when pos.kicked(t) then '{"error":"kicked"}'::jsonb when pos.expired(t) then '{"error":"expired"}'::jsonb else '{"error":"unauthorized"}'::jsonb end); end if;
  perform set_config('pos.sid', coalesce(me.store_id, 0)::text, true);
  own := me.role = 'owner';
  if me.role = 'new' and not (u in ('/api/me', '/api/logout', '/api/me/password', '/api/store/setup')) then
    return pos.r(403, '{"error":"Siapkan toko Anda dulu","code":"no-store"}');
  end if;

  if u = '/api/logout' and m = 'POST' then   -- keluar: sesi ini dihapus di server
    delete from pos.sessions where th = encode(extensions.digest(t, 'sha256'), 'hex');
    perform pos.audit(me.id, me.username, 'logout', '');
    return pos.r(200, '{"ok":true}');
  end if;

  if u = '/api/me' and m = 'GET' then return pos.r(200, pos.me_self(me)); end if;
  if u = '/api/me' and m = 'PUT' then
    declare pn text; pp text; pf text; pa text; pu text; pb date; psn text;
    begin
      -- email TIDAK diubah di sini: perubahan email harus lewat verifikasi (Supabase Auth) atau /api/me/link-email
      pn := regexp_replace(btrim(coalesce(b ->> 'name', me.name)), '\s+', ' ', 'g');
      pp := btrim(coalesce(b ->> 'phone', me.phone));
      pf := coalesce(b ->> 'photo', me.photo);
      pa := case when b ? 'address' then left(btrim(coalesce(b ->> 'address', '')), 300) else me.address end;
      pu := case when b ? 'username' then lower(btrim(coalesce(b ->> 'username', ''))) else me.username end;
      if length(pn) < 1 or length(pn) > 60 then return pos.r(400, '{"error":"Nama lengkap wajib diisi (maks. 60 karakter)"}'); end if;
      if pu <> me.username and not own then return pos.r(403, '{"error":"Username karyawan hanya bisa diubah oleh owner (dipakai untuk login dan jadwal shift)"}'); end if;
      if pu !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then return pos.r(400, '{"error":"Username 3-24 karakter: huruf kecil, angka, titik, strip, garis bawah"}'); end if;
      if pu <> me.username and exists (select 1 from pos.t_users where username = pu) then return pos.r(409, '{"error":"Username sudah dipakai"}'); end if;
      if pp <> '' and (pp !~ '^[0-9+() -]{6,20}$' or length(regexp_replace(pp, '\D', '', 'g')) < 6) then return pos.r(400, '{"error":"Nomor telepon tidak valid"}'); end if;
      if pf <> '' and (length(pf) > 110000 or pf !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then return pos.r(400, '{"error":"Foto profil tidak valid atau terlalu besar"}'); end if;
      if b ? 'birth' then
        if coalesce(b ->> 'birth', '') = '' then pb := null;
        elsif (b ->> 'birth') !~ '^\d{4}-\d{2}-\d{2}$' then return pos.r(400, '{"error":"Tanggal lahir tidak valid"}');
        else
          begin pb := (b ->> 'birth')::date; exception when others then return pos.r(400, '{"error":"Tanggal lahir tidak valid"}'); end;
          if pb < date '1900-01-01' or pb > current_date then return pos.r(400, '{"error":"Tanggal lahir tidak valid"}'); end if;
        end if;
      else pb := me.birth; end if;
      if own and b ? 'storeName' then
        psn := pos.clean(b ->> 'storeName', 60);
        if length(psn) < 2 then return pos.r(400, '{"error":"Nama toko minimal 2 karakter"}'); end if;
        update pos.stores set name = psn where id = me.store_id;
      end if;
      update pos.t_users set name = pn, username = pu, phone = pp, photo = pf, address = pa, birth = pb where id = me.id;
      if pu <> me.username then perform pos.audit(me.id, pu, 'ubah-username', me.username || ' -> ' || pu); end if;
      perform pos.audit(me.id, pu, 'ubah-profil', '');
      select * into me from pos.t_users where id = me.id;
      return pos.r(200, pos.me_self(me));
    end;
  end if;
  if u = '/api/me/password' and m = 'POST' then
    cnt := case when me.auth_id is null then 6 else 8 end;
    if coalesce(jsonb_typeof(b -> 'new'), '') <> 'string' or length(b ->> 'new') < cnt then
      return pos.r(400, jsonb_build_object('error', 'Sandi baru minimal ' || cnt || ' karakter')); end if;
    if length(b ->> 'new') > 200 then return pos.r(400, '{"error":"Sandi terlalu panjang"}'); end if;
    if not pos.pw_ok(me, coalesce(b ->> 'old', '')) then return pos.r(403, '{"error":"Sandi lama salah"}'); end if;
    perform pos.pw_set(me.id, b ->> 'new');
    delete from pos.sessions where uid = me.id;
    perform pos.audit(me.id, me.username, 'ganti-sandi', '');
    return pos.r(200, jsonb_build_object('token', pos.new_session(me.id), 'me', pos.me_self(me)));
  end if;

  if u = '/api/store/setup' and m = 'POST' then
    declare v_name text; v_tz text; v_code text; v_id bigint; i int;
    begin
      if me.role <> 'new' then return pos.r(409, '{"error":"Toko sudah disiapkan"}'); end if;
      if not pos.rate('store', 5, interval '1 hour') then return pos.r(429, '{"error":"Terlalu banyak percobaan. Coba lagi nanti."}'); end if;
      v_name := pos.clean(b ->> 'name', 60);
      if length(v_name) < 2 then return pos.r(400, '{"error":"Nama toko wajib diisi (min. 2 karakter)"}'); end if;
      v_tz := coalesce(nullif(btrim(b ->> 'tz'), ''), 'Asia/Jakarta');
      if not exists (select 1 from pg_timezone_names where name = v_tz) then return pos.r(400, '{"error":"Zona waktu tidak valid"}'); end if;
      for i in 1..8 loop
        v_code := (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + get_byte(extensions.gen_random_bytes(1), 0) % 31, 1), '') from generate_series(1, 8));
        exit when not exists (select 1 from pos.stores where stores.code = v_code);
      end loop;
      insert into pos.stores(code, name, owner_id) values (v_code, v_name, me.id) returning id into v_id;
      update pos.t_users set store_id = v_id, role = 'owner', single = null where id = me.id;
      perform set_config('pos.sid', v_id::text, true);
      insert into pos.doc(id, json, version) values (1, null, 0);
      insert into pos.meta(k, v) values ('rev', to_jsonb((extract(epoch from now()) * 1000)::bigint)), ('tz', to_jsonb(v_tz));
      perform pos.audit(me.id, me.username, 'buat-toko', v_name);
      select * into me from pos.t_users where id = me.id;
      return pos.r(200, pos.me_self(me));
    end;
  end if;
  if u = '/api/me/link-email' and m = 'POST' then
    -- akun lama menambahkan email: klien mendaftar ke Supabase Auth (kind=link) memakai sandi saat ini, lalu server mencocokkan
    if me.auth_id is not null then return pos.r(409, '{"error":"Akun ini sudah punya email"}'); end if;
    if not pos.rate('link', 10, interval '10 minutes') then return pos.r(429, '{"error":"Terlalu banyak percobaan. Coba lagi nanti."}'); end if;
    nm := lower(btrim(coalesce(b ->> 'email', '')));
    if nm !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' or length(nm) > 120 then return pos.r(400, '{"error":"Format alamat email tidak valid"}'); end if;
    if not pos.pw_ok(me, coalesce(b ->> 'password', '')) then return pos.r(403, '{"error":"Sandi saat ini salah"}'); end if;
    if exists (select 1 from pos.t_users where lower(email) = nm and id <> me.id) then return pos.r(409, '{"error":"Email sudah dipakai akun lain"}'); end if;
    select a.id into v_auth from auth.users a where lower(a.email) = nm and not exists (select 1 from pos.t_users x where x.auth_id = a.id)
      and a.encrypted_password = extensions.crypt(b ->> 'password', a.encrypted_password);
    if v_auth is null then return pos.r(409, '{"error":"Pendaftaran email belum selesai atau email sudah terdaftar. Coba lagi."}'); end if;
    update pos.t_users set auth_id = v_auth, email = nm, pw = '!' where id = me.id;
    perform pos.audit(me.id, me.username, 'tambah-email', nm);
    select * into me from pos.t_users where id = me.id;
    return pos.r(200, pos.me_self(me));
  end if;

  if u = '/api/users' and m = 'GET' then
    if not own then return pos.r(403, '{"error":"Anda tidak punya akses untuk ini"}'); end if;
    return pos.r(200, jsonb_build_object('perms', '["co","inv","hist","prn","set","att"]'::jsonb,
      'users', coalesce((select jsonb_agg(pos.me_view(uu) order by (uu.role = 'owner') desc, uu.username) from pos.users uu), '[]')));
  end if;
  if u = '/api/users' and m = 'POST' then
    if not own then return pos.r(403, '{"error":"Anda tidak punya akses untuk ini"}'); end if;
    un := lower(btrim(coalesce(b ->> 'username', ''))); nm := coalesce(nullif(pos.clean(b ->> 'name', 40), ''), un);
    if un !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then return pos.r(400, '{"error":"Username 3-24 karakter: huruf kecil, angka, titik, strip, garis bawah"}'); end if;
    if coalesce(jsonb_typeof(b -> 'password'), '') <> 'string' or length(b ->> 'password') < 6 then return pos.r(400, '{"error":"Sandi minimal 6 karakter"}'); end if;
    if exists (select 1 from pos.t_users where username = un) then return pos.r(409, '{"error":"Username sudah dipakai"}'); end if;
    nrole := case when lower(btrim(coalesce(b ->> 'role', ''))) = 'owner' then 'owner' else left(btrim(coalesce(b ->> 'role', 'staff')), 32) end;
    nperms := case when nrole = 'owner' then '[]'::jsonb
      else pos.clean_perms(case when b -> 'perms' is null or jsonb_typeof(b -> 'perms') = 'null' then '["co","prn"]'::jsonb else b -> 'perms' end) end;
    insert into pos.users(username, name, role, perms, pw, single) values (un, nm, nrole, nperms, extensions.crypt(b ->> 'password', extensions.gen_salt('bf', 10)),
      case when jsonb_typeof(b -> 'single') = 'boolean' then (b ->> 'single')::boolean end) returning * into tu;
    perform pos.audit(me.id, me.username, 'tambah-user', un || ' (' || nrole || ')');
    return pos.r(200, pos.me_view(tu));
  end if;
  mt := regexp_match(u, '^/api/users/(\d{1,15})$');
  if mt is not null and m in ('PUT', 'DELETE') then
    if not own then return pos.r(403, '{"error":"Anda tidak punya akses untuk ini"}'); end if;
    select * into tu from pos.users where id = mt[1]::bigint;
    if tu.id is null then return pos.r(404, '{"error":"pengguna tidak ada"}'); end if;
    select count(*) into cnt from pos.users where users.role = 'owner' and users.active;
    if m = 'DELETE' then
      if tu.id = me.id then return pos.r(400, '{"error":"Tidak bisa menghapus akun sendiri"}'); end if;
      if tu.role = 'owner' and tu.active and cnt <= 1 then return pos.r(400, '{"error":"Harus ada minimal satu owner aktif"}'); end if;
      delete from pos.users where id = tu.id;
      perform pos.audit(me.id, me.username, 'hapus-user', tu.username);
      return pos.r(200, '{"ok":true}');
    end if;
    nrole := case when b ? 'role' then (case when lower(btrim(coalesce(b ->> 'role', ''))) = 'owner' then 'owner' else left(btrim(coalesce(b ->> 'role', 'staff')), 32) end) else tu.role end;
    act := case when b ? 'active' then coalesce((b ->> 'active') in ('true', '1'), false) else tu.active end;
    nm := case when b ? 'name' then coalesce(nullif(pos.clean(b ->> 'name', 40), ''), tu.name) else tu.name end;
    nperms := case when nrole = 'owner' then '[]'::jsonb else pos.clean_perms(case when b ? 'perms' then b -> 'perms' else tu.perms end) end;
    if tu.role = 'owner' and tu.active and (nrole <> 'owner' or not act) and cnt <= 1 then return pos.r(400, '{"error":"Harus ada minimal satu owner aktif"}'); end if;
    if tu.id = me.id and (nrole <> 'owner' or not act) then return pos.r(400, '{"error":"Tidak bisa menurunkan/menonaktifkan akun sendiri"}'); end if;
    if b ? 'password' and (coalesce(jsonb_typeof(b -> 'password'), '') <> 'string' or length(b ->> 'password') < 6) then return pos.r(400, '{"error":"Sandi minimal 6 karakter"}'); end if;
    nsingle := case when b ? 'single' then (case jsonb_typeof(b -> 'single') when 'boolean' then (b ->> 'single')::boolean when 'null' then null else tu.single end) else tu.single end;
    update pos.users set name = nm, role = nrole, perms = nperms, active = act, single = nsingle where id = tu.id;
    if nrole <> tu.role or (not act and tu.active) then delete from pos.sessions where uid = tu.id; end if;
    if b ? 'password' then
      perform pos.pw_set(tu.id, b ->> 'password');
      delete from pos.sessions where uid = tu.id;
      perform pos.audit(me.id, me.username, 'reset-sandi', tu.username);
    end if;
    perform pos.audit(me.id, me.username, 'ubah-user', tu.username || ' role=' || nrole || ' aktif=' || (case when act then 1 else 0 end) || ' izin=' || (select coalesce(string_agg(e, ','), '') from jsonb_array_elements_text(nperms) e));
    select * into tu from pos.users where id = tu.id;
    return pos.r(200, pos.me_view(tu));
  end if;
  if u = '/api/audit' and m = 'GET' then
    if not own then return pos.r(403, '{"error":"Anda tidak punya akses untuk ini"}'); end if;
    return pos.r(200, jsonb_build_object('log', coalesce((select jsonb_agg(jsonb_build_object('t', pos.iso(a.t), 'uname', a.uname, 'action', a.action, 'detail', a.detail) order by a.id desc)
      from (select * from pos.audit order by id desc limit 100) a), '[]')));
  end if;

  -- absensi
  if u = '/api/att' and m = 'POST' then if not pos.can(me, 'att') then return pos.r(403, '{"error":"Anda tidak punya akses absensi"}'); end if; return pos.att_do(me, b); end if;
  if u = '/api/att' and m = 'GET' then if not pos.can(me, 'att') then return pos.r(403, '{"error":"Anda tidak punya akses absensi"}'); end if; return pos.att_list(me, q, own); end if;
  if u = '/api/att/photo' and m = 'GET' then
    if not pos.can(me, 'att') then return pos.r(403, '{"error":"Anda tidak punya akses absensi"}'); end if;
    select jsonb_build_object('photo', a.photo) into x from pos.att a where a.id = pos.num(q -> 'id')::bigint and (own or a.uid = me.id);
    if x is null then return pos.r(404, '{"error":"tidak ada"}'); end if;
    return pos.r(200, x);
  end if;

  -- pesanan online (kasir)
  if u = '/api/push/fcm' then   -- token notifikasi Android (APK)
    if not pos.can(me, 'co') then return pos.r(403, '{"error":"Anda tidak punya izin Pesanan Online"}'); end if;
    nm := btrim(coalesce(b ->> 'token', ''));
    if length(nm) < 20 or length(nm) > 4096 then return pos.r(400, '{"error":"token tidak valid"}'); end if;
    if m = 'POST' then
      insert into pos.push_tokens(tok, uid) values (nm, me.id) on conflict (tok) do update set uid = excluded.uid, created_at = now();
    elsif m = 'DELETE' then
      delete from pos.push_tokens where tok = nm and uid = me.id;
    else
      return pos.r(405, '{"error":"method"}');
    end if;
    return pos.r(200, '{"ok":true}');
  end if;
  if u like '/api/co%' and not pos.can(me, 'co') then return pos.r(403, '{"error":"Anda tidak punya izin Pesanan Online"}'); end if;
  if u = '/api/co' and m = 'GET' then
    rv := pos.rev(); wt := least(25, pos.num(q -> 'wait'));
    if pos.num(q -> 'rev') = rv and wt > 0 then return pos.r(200, jsonb_build_object('rev', rv, 'unchanged', true)); end if;
    return pos.r(200, jsonb_build_object('rev', rv, 'set', pos.co_set(), 'orders', coalesce((select jsonb_agg(pos.staff_view(c) order by c.id desc)
      from (select * from pos.co where status in ('new', 'accepted') or updated_at > now() - interval '2 days' order by id desc limit 200) c), '[]')));
  end if;
  if u = '/api/co/settings' and m = 'PUT' then
    if not pos.can(me, 'set') then return pos.r(403, '{"error":"Hanya owner atau pengguna dengan izin Pengaturan yang boleh membuka/menutup pemesanan"}'); end if;
    insert into pos.meta(k, v) values ('co', jsonb_build_object('on', not (b ? 'on' and b -> 'on' = 'false'::jsonb), 'msg', pos.clean(b ->> 'msg', 200),
      'nt', case when b ? 'nt' then pos.nt_clean(b -> 'nt') else coalesce((select m.v -> 'nt' from pos.meta m where m.k = 'co'), '{}'::jsonb) end))
      on conflict (store_id, k) do update set v = excluded.v;
    perform pos.bump();
    return pos.r(200, pos.co_set());
  end if;
  mt := regexp_match(u, '^/api/co/(\d{1,15})/proof$');
  if mt is not null and m = 'GET' then
    select * into r from pos.co where id = mt[1]::bigint;
    if r.id is null then return pos.r(404, '{"error":"tidak ada"}'); end if;
    return pos.r(200, jsonb_build_object('proof', r.proof));
  end if;
  mt := regexp_match(u, '^/api/co/(\d{1,15})(?:/(print))?$');
  if mt is not null and m = 'POST' then
    select * into r from pos.co where id = mt[1]::bigint;
    if r.id is null then return pos.r(404, '{"error":"tidak ada"}'); end if;
    if mt[2] is not null then
      ms := (extract(epoch from clock_timestamp()) * 1000)::bigint;
      if b ->> 'action' = 'claim' then
        update pos.co set printed = 1, claim_at = ms where id = r.id and (printed = 0 or (printed = 1 and claim_at < ms - 90000));
        get diagnostics cnt = row_count;
        return pos.r(200, jsonb_build_object('ok', cnt = 1));
      elsif b ->> 'action' = 'done' then update pos.co set printed = 2 where id = r.id;
      elsif b ->> 'action' = 'release' then update pos.co set printed = 0 where id = r.id and printed = 1;
      elsif b ->> 'action' = 'reset' then update pos.co set printed = 0 where id = r.id;
      else return pos.r(400, '{"error":"aksi?"}'); end if;
      perform pos.bump();
      return pos.r(200, '{"ok":true}');
    end if;
    if b ->> 'action' in ('paid', 'unpaid', 'reject') then
      if r.pay not in ('qris', 'duitnow') then return pos.r(400, '{"error":"bukan pesanan bayar online"}'); end if;
      if r.status = 'cancelled' then return pos.r(409, jsonb_build_object('error', 'sudah selesai', 'status', r.status)); end if;
      update pos.co set pst = case b ->> 'action' when 'paid' then 2 when 'reject' then 3 else 0 end,
        proof = case when b ->> 'action' = 'reject' then '' else proof end, updated_at = now() where id = r.id returning * into r;
      perform pos.bump();
      return pos.r(200, pos.staff_view(r));
    end if;
    nm := case b ->> 'action' when 'accept' then 'accepted' when 'cancel' then 'cancelled' when 'done' then 'done' end;
    if nm is null then return pos.r(400, '{"error":"aksi?"}'); end if;
    if r.status in ('done', 'cancelled') then return pos.r(409, jsonb_build_object('error', 'sudah selesai', 'status', r.status)); end if;
    update pos.co set status = nm, sale_no = coalesce(nullif(pos.clean(b ->> 'saleNo', 40), ''), sale_no), updated_at = now() where id = r.id returning * into r;
    perform pos.bump();
    return pos.r(200, pos.staff_view(r));
  end if;

  if u = '/api/version' and m = 'GET' then return pos.r(200, jsonb_build_object('version', (select version from pos.doc where id = 1))); end if;
  if u = '/api/data' and m = 'GET' then
    select * into d from pos.doc where id = 1;
    if q ->> 'since' = d.version::text and d.version > 0 then return pos.r(200, jsonb_build_object('version', d.version, 'unchanged', true)); end if;
    return pos.r(200, jsonb_build_object('version', d.version, 'updatedAt', pos.iso(d.updated_at), 'data', d.json));
  end if;
  if u = '/api/data' and m = 'PUT' then
    x := b -> 'data';
    if not coalesce(pos.valid_doc(x), false) or jsonb_typeof(b -> 'baseVersion') <> 'number' or (b ->> 'baseVersion')::numeric <> trunc((b ->> 'baseVersion')::numeric) then
      return pos.r(400, '{"error":"data tidak valid"}');
    end if;
    select * into d from pos.doc where id = 1 for update;
    gerr := pos.guard(me, d.json, x);
    if gerr is not null then perform pos.audit(me.id, me.username, 'ditolak', gerr); return pos.r(403, jsonb_build_object('error', gerr)); end if;
    if (b ->> 'baseVersion')::numeric <> d.version then return pos.r(409, jsonb_build_object('conflict', true, 'version', d.version, 'data', d.json)); end if;
    if d.json is not null then
      insert into pos.snapshots(day, json, version) values ((now() at time zone 'UTC')::date, d.json, d.version) on conflict do nothing;
      delete from pos.snapshots where day not in (select day from pos.snapshots order by day desc limit 30);
    end if;
    nv := d.version + 1;
    update pos.doc set json = x, version = nv, updated_at = now() where id = 1;
    return pos.r(200, jsonb_build_object('version', nv, 'updatedAt', pos.iso(now())));
  end if;

  if (u = '/api/export' or u like '/api/snapshots%') and not own then return pos.r(403, '{"error":"Khusus owner"}'); end if;
  if u = '/api/export' and m = 'GET' then return pos.r(200, coalesce((select json from pos.doc where id = 1), '{}'::jsonb)); end if;
  if u = '/api/snapshots' and m = 'GET' then
    return pos.r(200, jsonb_build_object('snapshots', coalesce((select jsonb_agg(jsonb_build_object('day', to_char(s.day, 'YYYY-MM-DD'), 'version', s.version,
      'created_at', pos.iso(s.created_at), 'size', octet_length(s.json::text)) order by s.day desc) from pos.snapshots s), '[]')));
  end if;
  mt := regexp_match(u, '^/api/snapshots/(\d{4}-\d{2}-\d{2})$');
  if mt is not null and m = 'GET' then
    begin
      select jsonb_build_object('version', s.version, 'data', s.json) into x from pos.snapshots s where s.day = mt[1]::date;
    exception when others then x := null; end;
    if x is null then return pos.r(404, '{"error":"tidak ada"}'); end if;
    return pos.r(200, x);
  end if;
  return pos.r(404, '{"error":"not found"}');
end $$;

-- ------------------------------------------------------------ satu-satunya pintu publik
create or replace function public.pos_api(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if jsonb_typeof(p) <> 'object' then return pos.r(400, '{"error":"bad request"}'); end if;
  return pos.route(upper(coalesce(p ->> 'm', 'GET')), coalesce(p ->> 'u', ''),
    case when jsonb_typeof(p -> 'q') = 'object' then p -> 'q' else '{}'::jsonb end,
    case when jsonb_typeof(p -> 'b') = 'object' then p -> 'b' else '{}'::jsonb end, p ->> 't');
exception when others then
  return pos.r(500, jsonb_build_object('error', 'server error',
    'detail', case when exists (select 1 from pos.meta where k = 'debug') then sqlerrm end));
end $$;

-- ------------------------------------------------------------ notifikasi pesanan online ke APK (opsional)
create extension if not exists pg_net with schema extensions;
create or replace function pos.nt_clean(j jsonb) returns jsonb language plpgsql immutable as $$
declare ev text; o jsonb := '{}'; c jsonb;
begin
  if jsonb_typeof(j) <> 'object' then return '{}'; end if;
  foreach ev in array array['new', 'pay', 'cancel'] loop
    c := j -> ev;
    if jsonb_typeof(c) = 'object' then
      o := o || jsonb_build_object(ev, jsonb_build_object('on', not (c ? 'on' and c -> 'on' = 'false'::jsonb),
        't', left(regexp_replace(coalesce(c ->> 't', ''), '[[:cntrl:]]', '', 'g'), 80),
        'b', left(regexp_replace(coalesce(c ->> 'b', ''), '[[:cntrl:]]', '', 'g'), 160)));
    end if;
  end loop;
  return o;
end $$;
create or replace function pos.nt_fmt(tpl text, r pos.co) returns text language sql stable as $$
  select btrim(regexp_replace(
    replace(replace(replace(replace(replace(replace(tpl, '{no}', r.num), '{nama}', r.name),
      '{meja}', case when r.tbl <> '' then 'Meja ' || r.tbl else '' end), '{total}', round(r.total, 2)::text), '{tipe}', r.type),
      '{item}', coalesce((select string_agg((l ->> 'qty') || 'x ' || (l ->> 'name'), ', ') from jsonb_array_elements(r.lines) l), '')),
    '\s+', ' ', 'g'), ' ·') $$;
drop trigger if exists co_push on pos.co;
drop function if exists pos.push_new();
-- ev: 'new' (pesanan baru), 'pay' (bukti bayar masuk), 'cancel' (dibatalkan pelanggan)
create or replace function pos.push_ev(ev text, r pos.co) returns void language plpgsql as $$
declare cfg jsonb; toks jsonb; nt jsonb; t text; b text;
begin
  select v into cfg from pos.t_meta where store_id = 0 and k = 'push';
  if cfg is null then return; end if;
  select v -> 'nt' -> ev into nt from pos.meta where k = 'co';
  if jsonb_typeof(nt) = 'object' and nt ? 'on' and nt -> 'on' = 'false'::jsonb then return; end if;
  select coalesce(jsonb_agg(tok), '[]'::jsonb) into toks from pos.push_tokens;
  if jsonb_array_length(toks) = 0 then return; end if;
  t := coalesce(nullif(nt ->> 't', ''), case ev when 'pay' then 'Pembayaran {no}' when 'cancel' then 'Dibatalkan {no}' else 'Pesanan online {no}' end);
  b := coalesce(nullif(nt ->> 'b', ''), case ev when 'pay' then '{nama} mengirim bukti bayar · {total}' when 'cancel' then '{nama} membatalkan pesanan' else '{nama} {meja} · {tipe} · {total}' end);
  perform net.http_post(
    url := cfg ->> 'url',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-key', cfg ->> 'key'),
    body := jsonb_build_object('tokens', toks, 'title', pos.nt_fmt(t, r), 'body', pos.nt_fmt(b, r)));
exception when others then
  return;   -- gagal kirim notifikasi tidak boleh menggagalkan pesanan
end $$;
-- Aktifkan:  select pos.admin_push('https://XXXX.supabase.co/functions/v1/notify-order', 'kunci-rahasia-Anda');
drop function if exists pos.admin_push(text, text);
create or replace function pos.admin_push(pu text, pk text) returns text language plpgsql as $$
begin
  if pu !~ '^https://' or length(coalesce(pk, '')) < 8 then raise exception 'url harus https dan kunci minimal 8 karakter'; end if;
  insert into pos.t_meta(store_id, k, v) values (0, 'push', jsonb_build_object('url', pu, 'key', pk)) on conflict (store_id, k) do update set v = excluded.v;
  return 'notifikasi APK aktif';
end $$;

-- ------------------------------------------------------------ hak akses
revoke all on schema pos from public, anon, authenticated;
revoke all on all tables in schema pos from public, anon, authenticated;
revoke all on all functions in schema pos from public, anon, authenticated;
revoke all on function public.pos_api(jsonb) from public;
grant execute on function public.pos_api(jsonb) to anon, authenticated;

-- ------------------------------------------------------------ alat admin (hanya dari SQL Editor)
-- Buat / pulihkan akun owner:   select pos.admin_owner('owner', 'sandi-anda-minimal-6');
create or replace function pos.admin_owner(nun text, npw text) returns text language plpgsql as $$
declare u pos.t_users; un text; vpw text;
begin
  un := lower(btrim(nun)); vpw := npw;
  if un !~ '^[a-z0-9][a-z0-9._-]{2,23}$' then raise exception 'username 3-24 karakter: huruf kecil/angka . _ -'; end if;
  if length(coalesce(vpw, '')) < 6 or vpw = 'ganti-dengan-sandi-yang-kuat' then raise exception 'sandi minimal 6 karakter dan jangan memakai contoh'; end if;
  if not exists (select 1 from pos.stores where id = 1) then
    insert into pos.stores(id, code, name) overriding system value values (1, substr(md5(random()::text), 1, 8), 'Ordela');
    perform setval(pg_get_serial_sequence('pos.stores', 'id'), 1);
    insert into pos.t_doc(store_id, id, json, version) values (1, 1, null, 0);
    insert into pos.t_meta(store_id, k, v) values (1, 'rev', to_jsonb((extract(epoch from now()) * 1000)::bigint));
  end if;
  select * into u from pos.t_users where username = un;
  if u.id is null then
    insert into pos.t_users(username, name, role, perms, pw, store_id) values (un, initcap(un), 'owner', '[]', extensions.crypt(vpw, extensions.gen_salt('bf', 10)), 1);
    return 'owner dibuat: ' || un;
  end if;
  update pos.t_users set role = 'owner', active = true, perms = '[]', pw = extensions.crypt(vpw, extensions.gen_salt('bf', 10)), store_id = coalesce(store_id, 1), auth_id = null where id = u.id;
  delete from pos.sessions where uid = u.id;
  return 'sandi owner direset: ' || un;
end $$;
-- Zona waktu toko (nomor antrean harian):  select pos.admin_tz('Asia/Makassar');
create or replace function pos.admin_tz(z text) returns text language plpgsql as $$
begin
  perform now() at time zone z;
  perform set_config('pos.sid', '1', true);
  insert into pos.meta(k, v) values ('tz', to_jsonb(z)) on conflict (store_id, k) do update set v = excluded.v;
  return 'zona waktu: ' || z;
end $$;
revoke all on all functions in schema pos from public, anon, authenticated;


-- ------------------------------------------------------------ hardening search_path fungsi internal
-- Fungsi di skema pos hanya dipanggil melalui router terkontrol public.pos_api.
-- Pastikan nama tabel/fungsi selalu dicari pada skema tepercaya dan pg_temp tetap terakhir.
do $secure_search_path$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'pos'
      and not coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=%'
  loop
    execute format('alter function %s set search_path to pg_catalog, pos, extensions, pg_temp', r.sig);
  end loop;
end
$secure_search_path$;
