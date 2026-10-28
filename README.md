# BaiGiuXe — Quản lý bãi giữ xe

ESP32 (2 đầu đọc RFID, barrier, OLED, bàn phím, vân tay) + 2 điện thoại làm camera chụp biển số + app Flutter quản lý, dùng chung CSDL Supabase. Danh sách thư viện và công nghệ chi tiết: [công nghệ.md](công%20nghệ.md).

```
ESP32 (WiFi bãi xe) --MQTT bgx/evt--> EMQX Cloud --> ĐT camera của cổng đó (WiFi hoặc 4G)
ĐT camera: chụp -> Plate Recognizer -> quyết định -> MQTT bgx/cmd -> ESP32: còi / OLED / barrier
ĐT camera ghi sessions, gate_events, attendance, ảnh vào Supabase
App quản lý: tổng quan, lịch sử + doanh thu, thẻ, bảo vệ + bảng công, cài đặt giá + ca trực
```

| Thư mục | Nội dung |
|---|---|
| `supabase/migrations/` | `0001_init.sql` bảng, RLS, RPC, bucket ảnh, realtime · `0002_ble.sql` hàm kiểm tra bảo vệ · `0003_entry_constraints.sql` ràng buộc xe vào · `0004_attendance.sql` ca trực + chấm công |
| `app/` | Flutter (Android / iOS / macOS). Một app, 3 vai trò: Quản lý, Camera cổng vào, Camera cổng ra (hoặc 1 ĐT cho cả 2 cổng) |
| `firmware/` | PlatformIO cho ESP32 DevKit V1 (`src/main.cpp` firmware chính, `src/hwtest.cpp` thử phần cứng) |

## 1. Supabase

1. Tạo project, mở **SQL Editor**, chạy lần lượt các file trong `supabase/migrations/` (`0001_init.sql` → `0004_attendance.sql`).
2. **Authentication → Sign In / Providers**: tắt *Allow new users to sign up* (chỉ admin tạo tài khoản).
3. **Authentication → Users → Add user**: tạo tài khoản nhân viên (tick *Auto Confirm User*). Một tài khoản dùng chung được cho app quản lý và 2 ĐT camera.
4. Gán vai trò `staff` bằng SQL (thiếu bước này thì đăng nhập được nhưng không đọc/ghi được dữ liệu):
   ```sql
   update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role":"staff"}' where email = 'nhanvien@...';
   ```
   User đang đăng nhập phải đăng xuất rồi đăng nhập lại thì role mới có hiệu lực.
5. Lấy `Project URL` và `Publishable key` trong **Project Settings → API Keys**.

ESP32 không cần tài khoản Supabase: nó chỉ nói chuyện với ĐT qua MQTT, ĐT lo phần CSDL.

## 2. Plate Recognizer

Đăng ký tại platerecognizer.com (gói free 2.500 lượt/tháng) và lấy API token.

## 3. EMQX Cloud (MQTT)

ESP32 và 2 ĐT camera nói chuyện qua broker MQTT, nên ĐT dùng WiFi hay 4G đều được, không cần đứng gần ESP32.

1. Đăng ký EMQX Cloud, tạo deployment **Serverless** (miễn phí).
2. **Overview**: chép địa chỉ broker (dạng `xxxx.ala.eu-central-1.emqxsl.com`), cổng TLS là 8883.
3. **Access Control → Authentication**: tạo 2 tài khoản, một cho ESP32 (ví dụ `esp32`), một cho app (ví dụ `phone`).

Đổi sang broker khác (HiveMQ...) thì thêm root CA của broker đó vào `firmware/src/ca_roots.h`.

## 4. App Flutter

```bash
cd app
flutter test
# Sửa app/dart_defines.json: SUPABASE_URL, SUPABASE_KEY, PLATE_TOKEN, MQTT_HOST, MQTT_USER, MQTT_PASS
flutter build apk --release --dart-define-from-file=dart_defines.json
```

Lần mở đầu tiên trên mỗi thiết bị, đăng nhập rồi chọn vai trò:
- **Camera cổng vào / ra** (Android, iOS): gắn điện thoại nhìn thẳng biển số, cắm sạc. Màn hình luôn sáng. Màn camera ở lại liên tục để quét xe xếp hàng, hiện 4 xe gần nhất.
- **Quản lý** (mọi nền tảng, kể cả macOS).

Các mục ở thanh dưới:

| Mục | Dùng để |
|---|---|
| Tổng quan | Số chỗ trống, xe trong bãi, sự kiện gần đây, nút mở cổng ra, cho xe ra khi mất thẻ |
| Lịch sử | Lượt gửi theo ngày, tìm biển số, doanh thu |
| Thẻ | Thêm thẻ (mở màn thêm thẻ rồi quẹt ở đầu đọc bất kỳ, UID tự điền), sửa, khoá, xoá |
| Bảo vệ | Thêm bảo vệ (tên + PIN), xem ai có vân tay, ai đang trực, mở **Bảng công** theo tháng |
| Cài đặt | Giá, sức chứa, mốc tính qua đêm, **ca trực** (giờ bắt đầu/kết thúc), đổi vai trò, đăng xuất |
| Camera | Chỉ có trên ĐT camera: quay lại màn camera |

Tính phí: lượt không qua mốc đêm (mặc định 22:00) tính giá ngày; mỗi lần qua mốc đêm tính một giá đêm. Vé tháng miễn phí.

## 5. Firmware ESP32

```bash
cd firmware
# Sửa src/secrets.h: WiFi 2.4GHz của bãi + tài khoản MQTT của ESP32 (mẫu: src/secrets.h.example)
pio run -t upload && pio device monitor
```

- **Đối chiếu `src/pins.h` với dây thật trước khi nạp.** Servo barrier ở chân 13, còi thụ động ở chân 19.
- Cần hiệu chỉnh trên phần cứng thật: `SERVO_OPEN_DEG` / `SERVO_CLOSE_DEG`, `KEYMAP` (nếu phím bấm ra sai ký tự), `EMERGENCY_ACTIVE`, `BUZZER_HZ` (nếu còi nhỏ).
- Nạp hay bị đứt giữa chừng thì hạ tốc độ: `PLATFORMIO_UPLOAD_SPEED=115200 pio run -t upload`.
- `src/ca_roots.h` chứa root CA cho TLS: DigiCert Global Root G2 (EMQX Cloud) và ISRG Root X1/X2 (Let's Encrypt).
- Dòng trạng thái trên OLED (vùng vàng): `Mat WiFi` → kiểm tra WiFi bãi; `Mat may chu MQTT` → kiểm tra địa chỉ / tài khoản MQTT; `Cho DT ket noi` → chưa có ĐT camera nào mở app.

### Bảo vệ: vân tay, PIN, chấm công

1. Trong app vào **Bảo vệ → Thêm bảo vệ**, nhập tên và PIN (4-8 số).
2. Đăng ký vân tay ở ESP32: **B** → PIN của bảo vệ đó → **#** → đặt ngón tay, nhấc ra, đặt lại. Vân tay lưu vào AS608 ở ô số = ID bảo vệ, app tự gán vân tay cho bảo vệ.
3. Chấm công: **C** → đặt vân tay (hoặc nhập PIN → **#**). Lần đầu là vào ca, lần sau là ra ca. Bảng công tính trễ / về sớm theo ca trực khai báo trong Cài đặt.

Đăng ký vân tay, mở cổng bằng PIN và chấm công đều cần ĐT cổng ra đang mở app (ĐT kiểm tra PIN và ghi CSDL). Mở cổng bằng vân tay đã đăng ký thì không cần mạng.

### Thao tác ở cổng
| Tình huống | ESP32 |
|---|---|
| Quẹt thẻ hợp lệ | 1 tiếng bíp, OLED hiện biển số; cổng ra thì barrier mở 5s |
| Bị từ chối (lệch biển, bãi đầy, thẻ lạ...) | 3 tiếng bíp, OLED hiện lý do |
| Bảo vệ mở tay | Đặt vân tay bất kỳ lúc nào, hoặc **A** → nhập PIN → **#**. Sai PIN 5 lần thì khoá 60s |
| Đăng ký vân tay | **B** → PIN bảo vệ → **#** → đặt ngón tay, nhấc ra, đặt lại. OLED báo `DA DANG KY` hoặc lý do lỗi |
| Chấm công vào/ra ca | **C** → đặt vân tay, hoặc nhập PIN → **#**. OLED báo `VAO CA` / `RA CA`, tên, giờ, số phút trễ/sớm |
| Khi đang nhập PIN | **C** = xoá 1 số, `*` = xoá hết, **D** = huỷ |
| Nút khẩn cấp | Bấm lần 1: mở và giữ barrier. Bấm lần 2: đóng. Không cần mạng |
| Mất thẻ | App → Tổng quan → chạm vào xe → *Cho xe ra + mở cổng* |

## Bảo mật

`app/dart_defines.json` và `firmware/src/secrets.h` **đang được đưa lên repo** (mật khẩu WiFi, mật khẩu MQTT, token Plate Recognizer, khoá Supabase). Nếu repo để công khai, hãy đổi các mật khẩu/token này định kỳ, hoặc đưa 2 file trở lại `.gitignore` và chỉ giữ file mẫu.

## Chưa làm (có chủ đích)
- Hàng đợi offline khi mất internet (vân tay đã đăng ký và nút khẩn cấp vẫn mở cổng được).
- Giấu `PLATE_TOKEN` sau Edge Function: hiện token nằm trong file build của app.
- Tự xoá ảnh cũ trong bucket `plates`.
- Sửa / xoá tay một lượt chấm công trong bảng công (hiện chỉ sửa được bằng SQL).
