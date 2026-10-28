-- Chấm công bảo vệ theo ca cố định. Bảo vệ bấm C ở ESP32 rồi đặt vân tay / nhập PIN;
-- ĐT cổng ra tự quyết vào hay ra ca và ghi vào bảng attendance.

create table public.shift_defs (
  id         int generated always as identity primary key,
  name       text not null,
  start_time time not null,
  end_time   time not null  -- end_time <= start_time = ca qua đêm
);
insert into public.shift_defs (name, start_time, end_time) values
  ('Ca sáng', '06:00', '14:00'),
  ('Ca chiều', '14:00', '22:00'),
  ('Ca đêm', '22:00', '06:00');

create table public.attendance (
  id          bigint generated always as identity primary key,
  guard_id    int not null references public.guards(id),  -- không cascade: giữ bảng công khi xoá bảo vệ
  shift_id    int references public.shift_defs(id) on delete set null,
  shift_name  text,         -- chép tên ca lúc chấm, đổi/xoá ca sau này không làm sai bảng công cũ
  shift_start timestamptz,  -- mốc ca theo lịch (đã gắn ngày) để tính trễ / về sớm
  shift_end   timestamptz,
  time_in     timestamptz not null default now(),
  time_out    timestamptz,
  method_in   text check (method_in in ('finger', 'pin')),
  method_out  text check (method_out in ('finger', 'pin', 'auto'))  -- auto = quên chấm ra
);
-- Mỗi bảo vệ chỉ có 1 ca đang mở.
create unique index attendance_one_open on public.attendance(guard_id) where time_out is null;
create index attendance_time_in on public.attendance(time_in desc);

alter table public.shift_defs enable row level security;
alter table public.attendance enable row level security;
create policy staff_all on public.shift_defs for all to authenticated using (public.app_role() = 'staff') with check (public.app_role() = 'staff');
create policy staff_all on public.attendance for all to authenticated using (public.app_role() = 'staff') with check (public.app_role() = 'staff');
