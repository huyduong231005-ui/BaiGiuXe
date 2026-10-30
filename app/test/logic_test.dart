import 'package:bai_giu_xe/logic.dart';
import 'package:flutter_test/flutter_test.dart';

// Quyết định ở cổng (vào / ra, phí, ca trực) đã chuyển lên API: xem backend/test/rules.test.js.
void main() {
  test('normPlate bỏ ký tự phân cách và viết hoa', () {
    expect(normPlate('59-x1 123.45'), '59X112345');
    expect(normPlate(null), '');
  });

  test('vé tháng còn hạn tới hết ngày valid_until, không ghi hạn = không giới hạn', () {
    Rec monthly([String? until]) => {'kind': 'monthly', 'valid_until': until};
    expect(monthlyValid(monthly('2026-10-30'), DateTime(2026, 10, 30, 23, 59)), isTrue);
    expect(monthlyValid(monthly('2026-10-29'), DateTime(2026, 10, 30, 9)), isFalse);
    expect(monthlyValid(monthly(), DateTime(2030)), isTrue);
    expect(monthlyValid({'kind': 'guest'}, DateTime(2026)), isFalse);
  });

  group('attStat', () {
    const base = {'shift_start': '2026-10-28T06:00:00Z', 'shift_end': '2026-10-28T14:00:00Z'};

    test('trễ 12 phút, về sớm 5 phút, làm 7h43', () {
      final s = attStat({...base, 'time_in': '2026-10-28T06:12:00Z', 'time_out': '2026-10-28T13:55:00Z'});
      expect((s.lateMin, s.earlyMin, s.workedMin, s.open), (12, 5, 463, false));
    });

    test('vào sớm, ra muộn: không trễ không sớm', () {
      final s = attStat({...base, 'time_in': '2026-10-28T05:50:00Z', 'time_out': '2026-10-28T14:10:00Z'});
      expect((s.lateMin, s.earlyMin), (0, 0));
    });

    test('đang trong ca: chưa tính giờ', () {
      final s = attStat({...base, 'time_in': '2026-10-28T06:00:00Z', 'time_out': null});
      expect((s.open, s.workedMin), (true, 0));
    });

    test('quên chấm ra: không tính giờ làm, không tính về sớm', () {
      final s = attStat(
          {...base, 'time_in': '2026-10-28T06:00:00Z', 'time_out': '2026-10-28T14:00:00Z', 'method_out': 'auto'});
      expect((s.missingOut, s.workedMin, s.earlyMin), (true, 0, 0));
    });
  });
}
