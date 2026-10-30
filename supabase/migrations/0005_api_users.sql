-- Tài khoản và mã OTP cho REST API (backend/ deploy trên Render).
-- Backend kết nối bằng chuỗi DATABASE_URL (role postgres, bỏ qua RLS). Bật RLS không kèm policy
-- để app gọi thẳng Supabase bằng publishable key không đọc được 2 bảng này.

create table public.app_users (
  id            int generated always as identity primary key,
  username      text not null unique check (username ~ '^[a-z0-9_.]{3,30}$'),
  email         text not null unique,
  full_name     text not null default '',
  password_hash text,               -- null với tài khoản tạo bằng Google
  google_id     text unique,
  role          text not null default 'guard' check (role in ('admin', 'manager', 'guard')),
  guard_id      int unique references public.guards(id) on delete set null, -- tài khoản bảo vệ gắn với hồ sơ bảo vệ
  active        boolean not null default false,  -- true sau khi xác minh email
  created_at    timestamptz not null default now()
);

create table public.otps (
  user_id    int not null references public.app_users(id) on delete cascade,
  purpose    text not null check (purpose in ('register', 'login')),
  code_hash  text not null,
  attempts   int not null default 0,
  expires_at timestamptz not null,
  primary key (user_id, purpose)
);

alter table public.app_users enable row level security;
alter table public.otps enable row level security;
