import 'package:bai_giu_xe/logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cfg = FeeConfig(priceDay: 3000, priceNight: 5000, nightMarkMinutes: 22 * 60);
  final guest = {'uid': 'A1B2C3D4', 'kind': 'guest', 'active': true};
  final monthly = {'uid': 'A1B2C3D5', 'kind': 'monthly', 'plate': '59-X1 123.45', 'active': true};

  test('normPlate bỏ ký tự phân cách và viết hoa', () {
    expect(normPlate('59-x1 123.45'), '59X112345');
    expect(normPlate(null), '');
  });

  group('samePlate (lệch tối đa 1 ký tự)', () {
    test('đúng các lỗi OCR đo được thực tế', () {
      expect(samePlate('29M303658', '29Y303658'), isTrue); // Y đọc thành M
      expect(samePlate('29Y303653', '29Y303658'), isTrue); // 8 đọc thành 3
      expect(samePlate('29Y30365', '29Y303658'), isTrue); // mất 1 ký tự
    });
    test('lệch 2 ký tự trở lên là xe khác', () {
      expect(samePlate('29M303653', '29Y303658'), isFalse);
      expect(samePlate('59X199999', '59X112345'), isFalse);
    });
    test('không phân biệt dấu và hoa thường', () {
      expect(samePlate('29-y3 036.58', '29Y303658'), isTrue);
    });
  });

  test('FeeConfig đọc được row settings', () {
    final c = FeeConfig.fromRow({'price_day': 1, 'price_night': 2, 'night_mark': '21:30:00'});
    expect(c.nightMarkMinutes, 21 * 60 + 30);
  });

  group('calcFee', () {
    test('trong ngày, không qua mốc đêm -> giá ngày', () {
      expect(calcFee(DateTime(2026, 10, 24, 8), DateTime(2026, 10, 24, 21, 59), cfg), 3000);
    });
    test('qua mốc đêm 1 lần -> 1 giá đêm', () {
      expect(calcFee(DateTime(2026, 10, 24, 20), DateTime(2026, 10, 25, 7), cfg), 5000);
    });
    test('vào đúng mốc đêm thì tính là qua đêm', () {
      expect(calcFee(DateTime(2026, 10, 24, 22), DateTime(2026, 10, 24, 23), cfg), 5000);
    });
    test('qua 2 đêm -> 2 giá đêm', () {
      expect(calcFee(DateTime(2026, 10, 24, 20), DateTime(2026, 10, 26, 7), cfg), 10000);
    });
    test('vé tháng miễn phí', () {
      expect(calcFee(DateTime(2026, 10, 24, 20), DateTime(2026, 10, 26, 7), cfg, monthly: true), 0);
    });
  });

  group('decideEntry', () {
    test('thẻ chưa đăng ký bị từ chối', () {
      expect(decideEntry(card: null, hasOpenSession: false, free: 10, plate: '59X112345').ok, isFalse);
    });
    test('thẻ bị khoá bị từ chối', () {
      final d = decideEntry(card: {...guest, 'active': false}, hasOpenSession: false, free: 10, plate: 'X');
      expect(d.ok, isFalse);
    });
    test('thẻ đang gửi xe bị từ chối', () {
      expect(decideEntry(card: guest, hasOpenSession: true, free: 10, plate: 'X').ok, isFalse);
    });
    test('bãi đầy bị từ chối', () {
      expect(decideEntry(card: guest, hasOpenSession: false, free: 0, plate: 'X').ok, isFalse);
    });
    test('không đọc được biển -> KHÔNG cho vào', () {
      final d = decideEntry(card: guest, hasOpenSession: false, free: 1, plate: null);
      expect(d.ok, isFalse);
      expect(d.message, 'Khong doc duoc bien');
    });
    test('đọc được nhưng độ tin cậy thấp -> KHÔNG cho vào', () {
      final d = decideEntry(card: guest, hasOpenSession: false, free: 1, plate: '29Y303658', score: 0.5);
      expect(d.ok, isFalse);
    });
    test('biển đã ở trong bãi (kể cả đọc lệch 1 ký tự) -> KHÔNG cho vào', () {
      final d = decideEntry(
          card: guest, hasOpenSession: false, free: 1, plate: '29M303658', parkedPlates: ['30A111111', '29Y303658']);
      expect(d.ok, isFalse);
      expect(d.message, 'Xe da o trong bai');
    });
    test('biển rõ, chưa có trong bãi -> cho vào', () {
      final d = decideEntry(
          card: guest, hasOpenSession: false, free: 1, plate: '29Y303658', score: 0.99, parkedPlates: ['30A111111']);
      expect(d.ok, isTrue);
    });
    test('mọi thông báo từ chối vừa 1 dòng OLED (21 ký tự)', () {
      for (final d in [
        decideEntry(card: guest, hasOpenSession: false, free: 1, plate: null),
        decideEntry(card: guest, hasOpenSession: false, free: 1, plate: 'X', score: 0.1),
        decideEntry(card: guest, hasOpenSession: false, free: 1, plate: 'X', parkedPlates: ['X']),
      ]) {
        expect(d.message.length, lessThanOrEqualTo(21));
      }
    });
    test('vé tháng sai xe bị từ chối, đúng xe thì cho vào', () {
      expect(decideEntry(card: monthly, hasOpenSession: false, free: 1, plate: '59X199999').ok, isFalse);
      expect(decideEntry(card: monthly, hasOpenSession: false, free: 1, plate: '59X112345').ok, isTrue);
    });
    test('message vừa màn OLED', () {
      final d = decideEntry(card: null, hasOpenSession: false, free: 1, plate: null);
      expect(d.message.length, lessThanOrEqualTo(21));
    });
  });

  group('decideExit', () {
    final session = {'id': 1, 'plate_in': '59X112345', 'time_in': '2026-10-24T13:00:00Z'};
    final now = DateTime.parse('2026-10-24T14:00:00Z');

    test('không có lượt gửi bị từ chối', () {
      expect(decideExit(card: guest, session: null, plateOut: '59X112345', now: now, cfg: cfg).ok, isFalse);
    });
    test('OCR lỗi lúc ra bị từ chối', () {
      expect(decideExit(card: guest, session: session, plateOut: null, now: now, cfg: cfg).ok, isFalse);
    });
    test('thiếu biển lúc vào bị từ chối', () {
      final s = {...session, 'plate_in': null};
      expect(decideExit(card: guest, session: s, plateOut: '59X112345', now: now, cfg: cfg).ok, isFalse);
    });
    test('lệch biển bị từ chối', () {
      expect(decideExit(card: guest, session: session, plateOut: '59X199999', now: now, cfg: cfg).ok, isFalse);
    });
    test('biển tốt nhất sai nhưng có trong candidates -> vẫn cho ra', () {
      final d = decideExit(
          card: guest, session: session, plateOut: '29M303653', candidates: ['29M303653', '59X112345'],
          now: now, cfg: cfg);
      expect(d.ok, isTrue);
    });
    test('candidates toàn biển khác -> từ chối', () {
      final d = decideExit(
          card: guest, session: session, plateOut: '30A999999', candidates: ['30A999999', '30A999998'],
          now: now, cfg: cfg);
      expect(d.ok, isFalse);
    });
    test('khớp biển -> mở cổng và tính phí', () {
      final d = decideExit(card: guest, session: session, plateOut: '59-x1 123.45', now: now, cfg: cfg);
      expect(d.ok, isTrue);
      expect(d.open, isTrue);
      expect(d.fee, isNotNull);
    });
  });

  group('nearestShift', () {
    final defs = [
      shiftDefFromRow({'id': 1, 'name': 'Sang', 'start_time': '06:00:00', 'end_time': '14:00:00'}),
      shiftDefFromRow({'id': 2, 'name': 'Chieu', 'start_time': '14:00:00', 'end_time': '22:00:00'}),
      shiftDefFromRow({'id': 3, 'name': 'Dem', 'start_time': '22:00:00', 'end_time': '06:00:00'}),
    ];

    test('vào trễ 10 phút -> ca sáng, mốc 06:00 cùng ngày', () {
      final s = nearestShift(defs, DateTime(2026, 10, 28, 6, 10))!;
      expect(s.def.name, 'Sang');
      expect(s.start, DateTime(2026, 10, 28, 6));
      expect(s.end, DateTime(2026, 10, 28, 14));
    });

    test('vào sớm 13:45 -> ca chiều', () {
      expect(nearestShift(defs, DateTime(2026, 10, 28, 13, 45))!.def.name, 'Chieu');
    });

    test('ca đêm kết thúc 06:00 hôm sau', () {
      final s = nearestShift(defs, DateTime(2026, 10, 28, 21, 50))!;
      expect(s.def.name, 'Dem');
      expect(s.end, DateTime(2026, 10, 29, 6));
    });

    test('vào trễ sau nửa đêm vẫn thuộc ca đêm hôm trước', () {
      final defsNight = [shiftDefFromRow({'id': 3, 'name': 'Dem', 'start_time': '23:30', 'end_time': '07:30'})];
      final s = nearestShift(defsNight, DateTime(2026, 10, 29, 0, 15))!;
      expect(s.start, DateTime(2026, 10, 28, 23, 30));
    });

    test('chưa khai báo ca -> null', () {
      expect(nearestShift(const [], DateTime(2026, 10, 28, 8)), isNull);
    });
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

  test('oledName lấy tên gọi, bỏ dấu', () {
    expect(oledName('Nguyễn Văn Tuấn'), 'Tuan');
    expect(oledName('Trần Đức'), 'Duc');
    expect(oledName('  Lê Thị Ưởng  '), 'Uong');
    expect(oledName('Hùng'), 'Hung');
  });

  group('vé tháng có hạn, thẻ báo mất', () {
    const cfg = FeeConfig(priceDay: 3000, priceNight: 5000, nightMarkMinutes: 22 * 60);
    final now = DateTime(2026, 10, 30, 9);
    Rec monthly([String? until]) => {'active': true, 'kind': 'monthly', 'plate': '59X112345', 'valid_until': until};
    Decision entry(Rec card) =>
        decideEntry(card: card, hasOpenSession: false, free: 5, plate: '59X112345', score: 0.95, now: now);

    test('còn hạn tới hết ngày valid_until', () {
      expect(entry(monthly('2026-10-30')).ok, isTrue);
      expect(monthlyValid(monthly('2026-10-30'), DateTime(2026, 10, 30, 23, 59)), isTrue);
      expect(entry(monthly()).ok, isTrue); // không ghi hạn = không giới hạn
    });

    test('hết hạn -> không cho vào', () {
      expect(entry(monthly('2026-10-29')).message, 'Ve thang het han');
    });

    test('hết hạn trong lúc đang gửi -> lúc ra tính phí như vé lượt', () {
      final session = {'plate_in': '59X112345', 'time_in': DateTime(2026, 10, 29, 8).toIso8601String()};
      expect(feeFor(session, monthly('2026-10-29'), now, cfg), 5000);
      expect(feeFor(session, monthly('2026-11-29'), now, cfg), 0);
    });

    test('thẻ đã báo mất: từ chối cả lúc vào và lúc ra', () {
      final lost = {...monthly('2026-12-31'), 'lost_at': '2026-10-30T01:00:00Z'};
      expect(entry(lost).message, 'The da bao mat');
      final d = decideExit(
          card: lost, session: {'plate_in': '59X112345', 'time_in': '2026-10-30T00:00:00Z'}, plateOut: '59X112345',
          now: now, cfg: cfg);
      expect((d.ok, d.open, d.message), (false, false, 'The da bao mat'));
    });
  });
}
