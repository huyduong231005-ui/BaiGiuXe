-- ESP32 chuyển sang BLE: điện thoại camera (role staff) kiểm tra PIN/vân tay bảo vệ thay cho ESP32.
-- ponytail: khoá sai PIN mới chỉ có trên ESP32; thêm bộ đếm phía server nếu tài khoản staff có thể bị lộ.
create or replace function public.find_guard(p_pin text default null, p_finger int default null)
returns int language sql stable security definer set search_path = '' as $$
  select g.id from public.guards g
  where public.app_role() in ('staff', 'device')
    and ((p_finger is not null and g.finger_id = p_finger)
      or (p_pin is not null and g.pin_hash is not null
          and g.pin_hash = extensions.crypt(p_pin, g.pin_hash)))
  limit 1
$$;
