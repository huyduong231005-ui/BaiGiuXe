-- Bãi giữ xe: schema + RLS + storage + realtime.
-- Vai trò lấy từ app_metadata.role của user: 'staff' (app quản lý + ĐT camera) | 'device' (ESP32).

create extension if not exists pgcrypto with schema extensions;

create or replace function public.app_role() returns text
language sql stable as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '')
$$;

-- ---------- Bảng ----------

create table public.settings (
  id          int primary key default 1 check (id = 1),
  capacity    int  not null default 50   check (capacity > 0),
  price_day   int  not null default 3000 check (price_day >= 0),
  price_night int  not null default 5000 check (price_night >= 0),
  night_mark  time not null default '22:00'
);
insert into public.settings default values;

create table public.cards (
  uid        text primary key check (uid ~ '^[0-9A-F]{8,20}$'),
  kind       text not null default 'guest' check (kind in ('guest', 'monthly')),
  plate      text,
  owner      text,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  check (kind = 'guest' or plate is not null)
);

create table public.guards (
  id        int generated always as identity primary key,
  name      text not null,
  finger_id int unique check (finger_id between 1 and 300),
  pin_hash  text
);

create table public.sessions (
  id          bigint generated always as identity primary key,
  card_uid    text not null references public.cards(uid),
  plate_in    text,
  plate_out   text,
  img_in      text,
  img_out     text,
  time_in     timestamptz not null default now(),
  time_out    timestamptz,
  fee         int check (fee >= 0),
  override_by int references public.guards(id)
);
-- 1 thẻ chỉ có 1 lượt đang gửi.
create unique index sessions_one_open_per_card on public.sessions(card_uid) where time_out is null;
create index sessions_time_in on public.sessions(time_in desc);

create table public.gate_events (
  id         bigint generated always as identity primary key,
  gate       text not null check (gate in ('in', 'out')),
  kind       text not null check (kind in ('scan', 'override', 'emergency', 'open_cmd')),
  uid        text,
  ref_id     bigint references public.gate_events(id),
  guard_id   int references public.guards(id),
  status     text not null default 'pending' check (status in ('pending', 'ok', 'denied', 'done')),
  plate      text,
  img        text,
  message    text,
  open       boolean not null default false,
  created_at timestamptz not null default now()
);
create index gate_events_pending on public.gate_events(kind) where status = 'pending';

-- Chạy bằng quyền owner để device đọc được số chỗ mà không cần quyền trên sessions.
create view public.parking_status as
  select s.capacity,
         count(x.id)::int              as occupied,
         (s.capacity - count(x.id))::int as free
  from public.settings s
  left join public.sessions x on x.time_out is null
  where public.app_role() in ('staff', 'device')
  group by s.capacity;

-- ---------- RPC ----------

-- Tìm bảo vệ theo PIN hoặc id vân tay trên AS608. Trả null nếu không khớp. Chỉ ESP32 được gọi.
-- ponytail: khoá sai PIN mới chỉ có trên ESP32; thêm bộ đếm phía server nếu tài khoản device có thể bị lộ.
create or replace function public.find_guard(p_pin text default null, p_finger int default null)
returns int language sql stable security definer set search_path = '' as $$
  select g.id from public.guards g
  where public.app_role() = 'device'
    and ((p_finger is not null and g.finger_id = p_finger)
      or (p_pin is not null and g.pin_hash is not null
          and g.pin_hash = extensions.crypt(p_pin, g.pin_hash)))
  limit 1
$$;

create or replace function public.set_guard_pin(p_id int, p_pin text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.app_role() <> 'staff' then raise exception 'forbidden'; end if;
  if p_pin !~ '^[0-9]{4,8}$' then raise exception 'PIN phải gồm 4-8 chữ số'; end if;
  update public.guards set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf'))
  where id = p_id;
end $$;

revoke execute on function public.find_guard(text, int), public.set_guard_pin(int, text) from public, anon;
grant execute on function public.find_guard(text, int), public.set_guard_pin(int, text) to authenticated;
revoke all on public.parking_status from anon;

-- ---------- RLS ----------

alter table public.settings    enable row level security;
alter table public.cards       enable row level security;
alter table public.guards      enable row level security;
alter table public.sessions    enable row level security;
alter table public.gate_events enable row level security;

create policy staff_all on public.settings    for all to authenticated using (public.app_role() = 'staff') with check (public.app_role() = 'staff');
create policy staff_all on public.cards       for all to authenticated using (public.app_role() = 'staff') with check (public.app_role() = 'staff');
create policy staff_all on public.guards      for all to authenticated using (public.app_role() = 'staff') with check (public.app_role() = 'staff');
create policy staff_all on public.sessions    for all to authenticated using (public.app_role() = 'staff') with check (public.app_role() = 'staff');
create policy staff_all on public.gate_events for all to authenticated using (public.app_role() = 'staff') with check (public.app_role() = 'staff');
create policy device_rw on public.gate_events for all to authenticated using (public.app_role() = 'device') with check (public.app_role() = 'device');

-- ---------- Storage: ảnh biển số ----------

insert into storage.buckets (id, name, public) values ('plates', 'plates', false)
on conflict (id) do nothing;

create policy plates_staff on storage.objects for all to authenticated
  using (bucket_id = 'plates' and public.app_role() = 'staff')
  with check (bucket_id = 'plates' and public.app_role() = 'staff');

-- ---------- Realtime ----------

alter publication supabase_realtime add table public.gate_events, public.sessions;
