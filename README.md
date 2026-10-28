# BaiGiuXe — Quản lý bãi giữ xe

ESP32 (2 đầu đọc RFID, barrier, OLED, phím, vân tay) + 2 điện thoại làm camera chụp biển số + app Flutter quản lý, dùng chung CSDL Supabase.

```
ESP32 (WiFi bãi xe) --MQTT bgx/evt--> HiveMQ Cloud --> ĐT camera của cổng đó (WiFi hoặc 4G)
ĐT camera: chụp -> Plate Recognizer -> quyết định -> MQTT bgx/cmd -> ESP32: còi / OLED / barrier
ĐT camera ghi sessions, gate_events, ảnh vào Supabase
App quản lý: tổng quan, lịch sử + doanh thu, thẻ, bảo vệ, giá
```

| Thư mục | Nội dung |
|---|---|
| `supabase/migrations/0001_init.sql` | Bảng, RLS, RPC, bucket ảnh, realtime |
| `app/` | Flutter (Android / iOS / macOS). Một app, 3 vai trò: Quản lý, Camera cổng vào, Camera cổng ra |
| `firmware/` | PlatformIO cho ESP32 DevKit V1 |

## 1. Supabase

1. Tạo project, mở **SQL Editor**, chạy lần lượt các file trong `supabase/migrations/` (`0001_init.sql` → `0004_attendance.sql`).
2. **Authentication → Sign In / Providers**: tắt *Allow new users to sign up* (chỉ admin tạo tài khoản).
3. **Authentication → Users → Add user**, tạo ít nhất:
   - một tài khoản cho nhân viên (dùng chung cho app quản lý và 2 ĐT camera, hoặc tạo riêng từng người);
   - một tài khoản cho ESP32.
4. Gán vai trò bằng SQL:
   ```sql
   update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role":"staff"}'  where email = 'nhanvien@...';
   update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role":"device"}' where email = 'esp32@...';
   ```
   User đang đăng nhập phải đăng xuất rồi đăng nhập lại thì role mới có hiệu lực.
5. Lấy `Project URL` và `Publishable key` (hoặc anon key cũ) trong **Project Settings → API Keys**.

## 2. Plate Recognizer

Đăng ký tại platerecognizer.com (gói free 2.500 lượt/tháng) và lấy API token.

## 2b. HiveMQ Cloud (MQTT)

ESP32 và 2 ĐT camera nói chuyện qua broker MQTT, nên ĐT dùng WiFi hay 4G đều được, không cần đứng gần ESP32.

1. Đăng ký console.hivemq.cloud, tạo cluster **Serverless (Free)**.
2. **Overview**: chép *Cluster URL* (dạng `xxxx.s1.eu.hivemq.cloud`), cổng TLS là 8883.
3. **Access Management → Credentials**: tạo 2 tài khoản, một cho ESP32, một cho app.

## 3. App Flutter

```bash
cd app
flutter test
# Điền app/dart_defines.json (gitignore): SUPABASE_URL, SUPABASE_KEY, PLATE_TOKEN, MQTT_HOST, MQTT_USER, MQTT_PASS
flutter run --dart-define-from-file=dart_defines.json
```

Lần mở đầu tiên trên mỗi thiết bị, chọn vai trò:
- **Camera cổng vào / ra** (Android, iOS): gắn điện thoại nhìn thẳng biển số, cắm sạc. Màn hình luôn sáng.
- **Quản lý** (mọi nền tảng, kể cả macOS).

Vào **Cài đặt** để chỉnh giá, sức chứa, mốc tính qua đêm và thêm bảo vệ (tên, ID vân tay, PIN). Vào **Thẻ → Thêm thẻ → biểu tượng quẹt thẻ** rồi quẹt thẻ ở đầu đọc bất kỳ để lấy UID.

Tính phí: lượt không qua mốc đêm (mặc định 22:00) tính giá ngày; mỗi lần qua mốc đêm tính một giá đêm. Vé tháng miễn phí.

## 4. Firmware ESP32

```bash
cd firmware
cp src/secrets.h.example src/secrets.h   # điền WiFi 2.4GHz của bãi + tài khoản HiveMQ của ESP32
pio run -t upload && pio device monitor
```

- **Đối chiếu `src/pins.h` với dây thật trước khi nạp.** Bảng chân được đọc lại từ sơ đồ.
- Cần hiệu chỉnh trên phần cứng thật: `SERVO_OPEN_DEG` / `SERVO_CLOSE_DEG`, `KEYMAP` (nếu phím bấm ra sai ký tự), `EMERGENCY_ACTIVE`.
- Đăng ký vân tay bảo vệ: tạo bảo vệ và đặt PIN trong app (Cài đặt → Bảo vệ), rồi ở ESP32 bấm **B** → PIN của bảo vệ đó → **#**, đặt cùng một ngón tay 2 lần. Vân tay lưu vào AS608 ở ô số = ID bảo vệ, app tự điền ID vân tay. Cần ĐT cổng ra đang chạy để kiểm tra PIN.
- `src/ca_roots.h` chứa root CA của Let's Encrypt (ISRG X1, X2), dùng cho TLS tới HiveMQ Cloud.
- Dòng 2 của OLED: `Mat WiFi` → kiểm tra WiFi bãi; `Mat may chu MQTT` → kiểm tra tài khoản/URL HiveMQ; `Cho DT ket noi` → chưa có ĐT camera nào mở app.

### Thao tác ở cổng
| Tình huống | ESP32 |
|---|---|
| Quẹt thẻ hợp lệ | 1 tiếng bíp, OLED hiện biển số; cổng ra thì barrier mở 5s |
| Bị từ chối (lệch biển, bãi đầy, thẻ lạ...) | 3 tiếng bíp, OLED hiện lý do |
| Bảo vệ mở tay | Quét vân tay bất kỳ lúc nào, hoặc **A** → nhập PIN → **#**. **C** = xoá 1 số, `*` = xoá hết, **D** = huỷ. Sai PIN 5 lần thì khoá 60s |
| Đăng ký vân tay | **B** → PIN bảo vệ → **#** → đặt ngón tay, nhấc ra, đặt lại. **D** = huỷ. OLED báo `DA DANG KY` hoặc lý do lỗi |
| Chấm công vào/ra ca | **C** → đặt vân tay, hoặc nhập PIN → **#**. Chưa trong ca thì vào ca gần nhất theo lịch, đang trong ca thì ra ca. OLED báo `VAO CA` / `RA CA`, tên, giờ, số phút trễ/sớm. Xem bảng công ở app: Bảo vệ → Bảng công |
| Nút khẩn cấp | Bấm lần 1: mở và giữ barrier. Bấm lần 2: đóng. Không cần mạng |
| Mất thẻ | App Quản lý → Tổng quan → chạm vào xe → *Cho xe ra + mở cổng* |

## Chưa làm (có chủ đích)
- Hàng đợi offline khi mất internet (hiện tại vân tay và nút khẩn cấp vẫn mở cổng được).
- So khớp biển số mờ: hiện so khớp chính xác, lệch thì bảo vệ mở tay.
- Giấu `PLATE_TOKEN` sau Edge Function: hiện token nằm trong file build của app.
- Tự xoá ảnh cũ trong bucket `plates`.
