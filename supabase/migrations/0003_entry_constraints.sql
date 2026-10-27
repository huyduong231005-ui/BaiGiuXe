-- Ràng buộc xe vào ở tầng CSDL (phòng khi app có lỗi):
--   1. Lượt gửi mới bắt buộc có biển số (không đọc được biển thì không cho vào).
--   2. Một biển chỉ có MỘT lượt đang gửi (không vào 2 lần bằng 2 thẻ).
--
-- Trước khi chạy, xem có lượt đang gửi nào trùng biển không (do các lần test trước):
--   select plate_in, count(*) from public.sessions
--   where time_out is null group by plate_in having count(*) > 1;
-- Nếu có: vào app Quản lý -> Tổng quan -> chạm từng xe -> "Cho xe ra" để đóng bớt, rồi chạy file này.

-- NOT VALID: chỉ áp cho dòng mới, không bắt các lượt cũ (lúc trước cho vào khi không đọc được biển) phải có biển.
alter table public.sessions
  add constraint sessions_plate_in_required check (plate_in is not null and plate_in <> '') not valid;

create unique index sessions_one_open_per_plate on public.sessions(plate_in) where time_out is null;
