# Công nghệ sử dụng — Hệ thống quản lý bãi giữ xe

Tài liệu liệt kê toàn bộ phần cứng, thư viện, dịch vụ và công cụ dùng trong dự án, kèm phiên bản đang dùng và vai trò của từng thứ.

## 1. Tổng quan kiến trúc

```
                 MQTT over TLS (cổng 8883)
  ESP32  <------------------------------------>  EMQX Cloud  <------>  2 điện thoại camera
 (WiFi bãi xe)    bgx/evt, bgx/cmd, bgx/esp,       (broker)           (WiFi hoặc 4G)
                  bgx/phone/<cổng>                                         |
                                                                           | HTTPS
                                          Plate Recognizer API  <----------+  (đọc biển số)
                                                                           |
                                          Supabase  <----------------------+  (CSDL, ảnh, đăng nhập)
                                              ^
                                              |  HTTPS + Realtime (WebSocket)
                                          App quản lý (Android / iOS / macOS)
```

Luồng một lượt quẹt thẻ:
1. ESP32 đọc UID thẻ RFID, gửi sự kiện `scan` lên MQTT.
2. Điện thoại camera của cổng đó nhận sự kiện, chụp ảnh và gửi lên Plate Recognizer để đọc biển số.
3. Điện thoại kiểm tra thẻ và lượt gửi trong Supabase, quyết định cho qua hay từ chối, rồi gửi kết quả về ESP32 qua MQTT.
4. ESP32 bíp còi, hiện kết quả lên OLED và mở barrier (ở cổng ra).
5. Điện thoại lưu ảnh và nhật ký vào Supabase. App quản lý thấy cập nhật ngay qua Realtime.

## 2. Phần cứng

| Linh kiện | Giao tiếp | Chân ESP32 | Vai trò |
|---|---|---|---|
| ESP32 DevKit V1 | — | — | Bộ điều khiển trung tâm, có WiFi |
| 2 × RC522 (RFID 13,56 MHz) | SPI (VSPI và HSPI) | Vào: SS 5, SCK 18, MOSI 23, MISO 36, RST 4 · Ra: SS 27, SCK 14, MOSI 32, MISO 35, RST 33 | Đọc thẻ ở cổng vào và cổng ra |
| Bàn phím 4×4 qua PCF8574 | I2C (địa chỉ 0x20) | SDA 21, SCL 22 | Bảo vệ nhập PIN mở cổng |
| OLED SSD1306 0,96" 128×64, 2 màu | I2C (0x3C) | SDA 21, SCL 22 | Hiện giờ, trạng thái, biển số, lý do |
| DS3231 (đồng hồ thời gian thực) | I2C (0x68) | SDA 21, SCL 22 | Giữ giờ khi mất điện, đồng bộ theo điện thoại |
| AS608 (cảm biến vân tay) | UART2, 57600 baud | RX 16, TX 17 | Bảo vệ mở cổng bằng vân tay, không cần mạng |
| Servo | PWM 50 Hz | 13 | Barrier cổng ra |
| Còi thụ động | PWM 2,7 kHz (LEDC kênh 15) | 19 | Bíp báo kết quả |
| Nút khẩn cấp | Digital, trở kéo lên 10k ngoài | 34 | Mở/đóng barrier tức thì, không cần mạng |
| 2 điện thoại Android | — | — | Camera chụp biển số ở mỗi cổng |

Bảng chân chi tiết nằm ở `firmware/src/pins.h`.

## 3. Firmware ESP32

Nền tảng build:

| Thành phần | Phiên bản | Ghi chú |
|---|---|---|
| PlatformIO | — | Công cụ build và nạp firmware (`firmware/platformio.ini`) |
| Platform `espressif32` | 6.9.0 | |
| Framework Arduino-ESP32 | 2.0.17 | Kèm sẵn `WiFi`, `WiFiClientSecure` (TLS bằng mbedTLS), `Wire` (I2C), `SPI`, LEDC (PWM), FreeRTOS |

Thư viện:

| Thư viện | Phiên bản | Dùng để |
|---|---|---|
| RFID_MFRC522v2 (OSSLibraries) | 2.0.6 | Điều khiển 2 đầu đọc RC522 trên 2 bus SPI |
| I2CKeyPad (robtillaart) | 0.5.2 | Quét bàn phím 4×4 qua PCF8574 |
| Adafruit SSD1306 | 2.5.17 | Điều khiển màn OLED |
| Adafruit GFX Library | 1.13.0 | Vẽ chữ, kèm font FreeSans / FreeSansBold 9pt và 12pt |
| Adafruit BusIO | 1.17.4 | Thư viện phụ thuộc của Adafruit (I2C/SPI) |
| RTClib (Adafruit) | 2.1.4 | Đọc và chỉnh giờ DS3231 |
| Adafruit Fingerprint Sensor Library | 2.1.4 | Giao tiếp cảm biến vân tay AS608 |
| ESP32Servo | 3.2.1 | Điều khiển servo barrier |
| ArduinoJson | 7.4.3 | Tạo và đọc bản tin JSON trao đổi với điện thoại |
| PubSubClient (knolleary) | 2.8 | MQTT client: kết nối broker, publish/subscribe, LWT |

Chứng chỉ gốc cho TLS nằm trong `firmware/src/ca_roots.h` (DigiCert Global Root G2 cho EMQX Cloud, ISRG Root X1/X2 cho Let's Encrypt). Thông tin WiFi và MQTT nằm trong `firmware/src/secrets.h` (không đưa lên git).

Ngoài firmware chính còn có firmware kiểm tra phần cứng `firmware/src/hwtest.cpp`, nạp bằng `pio run -e hwtest`, dùng để dò chân và thử từng linh kiện.

## 4. Ứng dụng điện thoại (Flutter)

| Thành phần | Phiên bản |
|---|---|
| Flutter | 3.47.3 (stable) |
| Dart | SDK ^3.13 |
| Nền tảng | Android, iOS, macOS (macOS chỉ dùng vai trò Quản lý) |

Một app có 3 vai trò, chọn khi mở lần đầu: **Quản lý**, **Camera cổng vào**, **Camera cổng ra** (hoặc **Camera cả 2 cổng**).

Thư viện:

| Gói | Phiên bản | Dùng để |
|---|---|---|
| supabase_flutter | 2.18.3 | Đăng nhập, đọc/ghi CSDL, tải ảnh lên Storage, nhận thay đổi Realtime |
| mqtt_client | 10.14.0 | Kết nối MQTT (TLS) tới broker để nói chuyện với ESP32, tự kết nối lại khi rớt mạng |
| camera | 0.12.1 | Mở camera sau, chụp ảnh 1080p, lấy nét và đo sáng vào giữa khung |
| image | 4.12.0 | Cắt vùng biển số và nén JPEG ngay trên điện thoại trước khi gửi đi |
| http | 1.6.0 | Gửi ảnh tới API Plate Recognizer |
| wakelock_plus | 1.8.2 | Giữ màn hình điện thoại camera luôn sáng |
| shared_preferences | 2.5.6 | Lưu vai trò thiết bị và mức zoom camera |
| cupertino_icons | 1.0.9 | Bộ icon |
| flutter_test (dev) | theo SDK | Kiểm thử đơn vị (`app/test/`) |
| flutter_lints (dev) | 6.0.0 | Quy tắc kiểm tra code |

Giao diện dùng Material 3 (sáng/tối theo hệ thống). Khoá API và thông tin máy chủ truyền vào lúc build qua `--dart-define-from-file=dart_defines.json` (không đưa lên git).

## 5. Dịch vụ đám mây

### Supabase (CSDL và backend)

| Tính năng | Dùng để |
|---|---|
| PostgreSQL | Các bảng `settings`, `cards`, `guards`, `sessions`, `gate_events` và view `parking_status` |
| Auth (email + mật khẩu) | Đăng nhập nhân viên. Vai trò lưu trong `app_metadata.role` (`staff`) |
| Row Level Security | Chỉ tài khoản `staff` mới đọc/ghi được dữ liệu |
| RPC (hàm SQL) | `find_guard` kiểm tra PIN/vân tay bảo vệ, `set_guard_pin` đặt PIN |
| pgcrypto | Băm PIN bảo vệ bằng bcrypt (`crypt`, `gen_salt('bf')`) |
| Storage (bucket private `plates`) | Lưu ảnh biển số lúc vào và lúc ra |
| Realtime | App quản lý cập nhật ngay khi có xe ra vào. Màn thêm thẻ nhận UID khi quẹt |

Các file migration nằm trong `supabase/migrations/`:
- `0001_init.sql`: tạo bảng, RLS, RPC, bucket ảnh, realtime.
- `0002_ble.sql`: cập nhật hàm kiểm tra bảo vệ.
- `0003_entry_constraints.sql`: ràng buộc xe vào phải có biển số, và mỗi biển chỉ có một lượt đang gửi.

### EMQX Cloud Serverless (MQTT broker)

- Giao thức MQTT 3.1.1 qua TLS, cổng 8883.
- Hai tài khoản riêng: một cho ESP32, một cho app.
- Topic:

| Topic | Chiều | Nội dung |
|---|---|---|
| `bgx/evt` | ESP32 → ĐT | Sự kiện: quẹt thẻ, xác thực bảo vệ, khẩn cấp |
| `bgx/cmd` | ĐT → ESP32 | Lệnh: kết quả quẹt, mở cổng, số chỗ trống, chỉnh giờ, kết quả PIN |
| `bgx/esp` | ESP32 → ĐT | `1`/`0`: ESP32 online/offline (retained + Last Will) |
| `bgx/phone/in`, `bgx/phone/out`, `bgx/phone/both` | ĐT → ESP32 | `1`/`0`: điện thoại của cổng đó online/offline (retained + Last Will) |

Nhờ dùng MQTT qua Internet, điện thoại camera dùng WiFi hay 4G đều được, không cần đứng gần ESP32.

### Plate Recognizer (nhận diện biển số)

- API REST `https://api.platerecognizer.com/v1/plate-reader/`, tham số `regions=vn` (biển Việt Nam).
- Trả về biển số, độ tin cậy (`score`) và các cách đọc khác (`candidates`).
- Gói miễn phí: 2.500 lượt/tháng. Mỗi ảnh đã cắt mất khoảng 1,4 giây.

## 6. Công cụ phát triển

| Công cụ | Dùng để |
|---|---|
| Visual Studio Code, Android Studio | Viết code |
| Flutter SDK, Android SDK, ADB | Build và cài app lên điện thoại |
| PlatformIO | Build và nạp firmware ESP32, xem Serial |
| Git | Quản lý mã nguồn |
| Supabase Dashboard | Tạo tài khoản, chạy SQL, xem dữ liệu |
| EMQX Cloud Console | Tạo broker và tài khoản MQTT |

## 7. Bảo mật

| Vấn đề | Cách xử lý |
|---|---|
| Kết nối ESP32 và app | MQTT qua TLS. ESP32 kiểm tra chứng chỉ máy chủ bằng root CA nhúng sẵn |
| Truy cập dữ liệu | RLS trong Supabase: chỉ tài khoản `staff` |
| PIN bảo vệ | Băm bcrypt trong CSDL. ESP32 khoá 60 giây sau 5 lần nhập sai |
| Ảnh biển số | Bucket private, xem qua link có hạn 1 giờ |
| Khoá bí mật | `secrets.h` và `dart_defines.json` không đưa lên git |
| Hạn chế còn lại | Token Plate Recognizer và mật khẩu MQTT của app nằm trong file cài đặt app |
