import 'dart:typed_data';

import 'package:bai_giu_xe/nfc.dart';
import 'package:bai_giu_xe/screens/revenue_chart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uidHex: UID đọc bằng NFC điện thoại cùng định dạng với RC522 ở cổng', () {
    expect(uidHex(Uint8List.fromList([0xA1, 0xB2, 0x0C, 0x04])), 'A1B20C04');
    expect(uidHex(Uint8List.fromList([0x04, 0x5A, 0x1F, 0x22, 0x6B, 0x70, 0x80])), '045A1F226B7080');
  });

  test('fillDays: đủ 7 ngày kết thúc hôm nay, ngày không có doanh thu là 0', () {
    final d = fillDays([
      {'day': '2026-10-28', 'revenue': 8000, 'sessions': 2},
      {'day': '2026-10-30', 'revenue': 3000, 'sessions': 1},
    ], DateTime(2026, 10, 30, 15));
    expect(d.length, 7);
    expect(d.first.day, DateTime(2026, 10, 24));
    expect(d.last.day, DateTime(2026, 10, 30));
    expect([for (final x in d) x.revenue], [0, 0, 0, 0, 8000, 0, 3000]);
    // Qua đầu tháng không lệch ngày
    expect(fillDays(const [], DateTime(2026, 11, 2)).first.day, DateTime(2026, 10, 27));
  });
}
