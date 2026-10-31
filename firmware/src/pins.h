#pragma once
// Bảng chân đã đo trên phần cứng thật bằng firmware hwtest (pio run -e hwtest).

// RC522 cổng vào - bus HSPI (main.cpp / hwtest.cpp). MISO dùng chân chỉ-vào 36 (VP). Đã đo bằng hwtest.
#define RFID_IN_SS   5
#define RFID_IN_SCK  18
#define RFID_IN_MOSI 26  // dây thật đang ở D26 (trước là D23)
#define RFID_IN_MISO 36
#define RFID_IN_RST  4

// RC522 cổng ra - bus VSPI (SPI mặc định). Đã đo bằng hwtest lệnh 'p' (dò chân tự động).
#define RFID_OUT_SS   27
#define RFID_OUT_SCK  14
#define RFID_OUT_MOSI 32
#define RFID_OUT_MISO 35
#define RFID_OUT_RST  33

// I2C chung: PCF8574 (phím 4x4) 0x20, DS3231 0x68, OLED 0x3C
#define I2C_SDA 21
#define I2C_SCL 22
#define PCF8574_ADDR 0x20
#define OLED_ADDR    0x3C

// AS608 trên UART2
#define FP_RX 16  // nối TX của AS608
#define FP_TX 17  // nối RX của AS608

// Còi, servo: đã đo bằng hwtest lệnh 'g' (dò chân bằng bàn phím). Hệ thống không dùng LED.

#define BUZZER_PIN    19  // lúc dò, chân 25 cũng được báo là còi: kiểm lại nếu còi không kêu
// Còi thật là loại thụ động: bật DC chỉ kêu "tạch" nhỏ, phải phát xung. Đổi 0 nếu thay bằng còi active.
#define BUZZER_PASSIVE 1
#define BUZZER_HZ      2700  // tần số cộng hưởng phổ biến của còi 12mm, kêu to nhất
#define SERVO_PIN     13  // dây thật ở D13 (bản dò hwtest cũ ghi 26)
#define EMERGENCY_PIN 34  // chân chỉ-vào, dùng trở 10k ngoài
#define EMERGENCY_ACTIVE LOW  // đo thực tế: trở kéo lên, nhấn nối xuống GND -> nhấn = LOW

// Bàn phím 4x4 qua PCF8574: vị trí quét 0..15 -> ký tự, thêm N (không phím), F (lỗi).
// Bàn phím thực tế đang được đọc ngược 180° so với sơ đồ (đo bằng hwtest, lệnh 'k').
static const char KEYMAP[] = "D#0*C987B654A321NF";

