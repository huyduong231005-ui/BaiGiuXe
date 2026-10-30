-- Khách hàng = chủ vé tháng (cư dân, nhân viên, sinh viên gửi xe thường xuyên).
-- Đăng ký / gia hạn vé tháng online, báo mất thẻ, xem lịch sử ra vào kèm ảnh, vé tháng có hạn dùng.

-- Tài khoản tự đăng ký là khách hàng; quản lý / bảo vệ do admin cấp quyền.
alter table public.app_users drop constraint app_users_role_check;
alter table public.app_users add constraint app_users_role_check check (role in ('admin', 'manager', 'guard', 'customer'));
alter table public.app_users alter column role set default 'customer';

alter table public.cards
  add column user_id     int references public.app_users(id) on delete set null, -- chủ thẻ có tài khoản app
  add column valid_until date,        -- vé tháng dùng tới hết ngày này (null = không giới hạn, vé lượt)
  add column lost_at     timestamptz; -- chủ thẻ báo mất: cổng từ chối cả lúc vào lẫn lúc ra
create index cards_user on public.cards(user_id);

-- Bãi xe để khách xem trên bản đồ.
alter table public.settings
  add column lot_name text not null default 'Bãi giữ xe',
  add column address  text,
  add column lat      double precision,
  add column lng      double precision;

create table public.ticket_requests (
  id          bigint generated always as identity primary key,
  user_id     int not null references public.app_users(id) on delete cascade,
  card_uid    text references public.cards(uid) on delete set null, -- có = gia hạn thẻ đang dùng; null = đăng ký mới
  plate       text not null check (plate ~ '^[A-Z0-9]{5,12}$'),
  owner_name  text not null,
  months      int not null check (months between 1 and 12),
  note        text,
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  reply       text,      -- lý do từ chối / lời nhắn của quản lý
  handled_by  int references public.app_users(id) on delete set null,
  handled_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index ticket_requests_status on public.ticket_requests(status, created_at desc);

alter table public.ticket_requests enable row level security;
