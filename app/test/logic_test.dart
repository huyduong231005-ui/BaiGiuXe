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
    test('OCR không đọc được vẫn cho vào', () {
      expect(decideEntry(card: guest, hasOpenSession: false, free: 1, plate: null).ok, isTrue);
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
    test('khớp biển -> mở cổng và tính phí', () {
      final d = decideExit(card: guest, session: session, plateOut: '59-x1 123.45', now: now, cfg: cfg);
      expect(d.ok, isTrue);
      expect(d.open, isTrue);
      expect(d.fee, isNotNull);
    });
  });
}
