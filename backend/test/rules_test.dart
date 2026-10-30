// Cùng các ca với app/test/logic_test.dart: API và app phải tính giống nhau. Không cần MongoDB.
import 'package:bai_giu_xe_api/src/auth.dart' show checkPassword;
import 'package:bai_giu_xe_api/src/jwt.dart';
import 'package:bai_giu_xe_api/src/layout.dart';
import 'package:bai_giu_xe_api/src/rules.dart';
import 'package:test/test.dart';

const cfg = {'price_day': 3000, 'price_night': 5000, 'night_mark': '22:00:00'};
DateTime at(int d, int h, [int m = 0]) => DateTime(2026, 10, d, h, m);

void main() {
  setUpAll(() {
    if (DateTime.now().timeZoneOffset != const Duration(hours: 7)) {
      throw StateError('Test cần múi giờ Việt Nam (UTC+7): đặt TZ=Asia/Ho_Chi_Minh');
    }
  });

  test('normPlate bỏ ký tự phân cách, viết hoa', () {
    expect(normPlate('59x1-123.45'), '59X112345');
    expect(normPlate(null), '');
  });

  test('samePlate chấp nhận lệch 1 ký tự, lệch 2 là xe khác', () {
    expect(samePlate('59X112345', '59M112345'), isTrue);
    expect(samePlate('59X112345', '59X11234'), isTrue);
    expect(samePlate('59X112345', '59M112346'), isFalse);
  });

  test('calcFee: trong ngày, qua 1 đêm, đúng mốc đêm, qua 2 đêm, vé tháng', () {
    expect(calcFee(at(28, 8), at(28, 21, 59), cfg), 3000);
    expect(calcFee(at(28, 20), at(29, 7), cfg), 5000);
    expect(calcFee(at(28, 22), at(28, 23), cfg), 5000);
    expect(calcFee(at(28, 20), at(30, 7), cfg), 10000);
    expect(calcFee(at(28, 20), at(30, 7), cfg, true), 0);
  });

  test('decideEntry kiểm lần lượt từng quy tắc', () {
    Map entry({Map? card = const {'active': true, 'kind': 'guest'}, bool open = false, num free = 5,
            Object? plate = '59X112345', num score = 0.95, List parked = const []}) =>
        decideEntry(card: card, hasOpenSession: open, free: free, plate: plate, score: score, parkedPlates: parked);
    expect(entry(card: null)['message'], 'The chua dang ky');
    expect(entry(card: {'active': false})['message'], 'The bi khoa');
    expect(entry(open: true)['message'], 'The dang gui xe');
    expect(entry(free: 0)['message'], 'Bai da day');
    expect(entry(plate: null)['message'], 'Khong doc duoc bien');
    expect(entry(score: 0.5)['message'], 'Bien mo, quet lai');
    expect(entry(parked: ['59M112345'])['message'], 'Xe da o trong bai');
    expect(entry(card: {'active': true, 'kind': 'monthly', 'plate': '30A99999'})['message'], 'Sai xe ve thang');
    expect(entry(), {'ok': true, 'open': false, 'message': 'Moi vao'});
  });

  test('decideExit: lệch biển từ chối, khớp candidates thì mở cổng kèm phí', () {
    final session = {'plate_in': '59X112345', 'time_in': at(28, 8)};
    Map exit({Map? s, Object? plate, List candidates = const []}) => decideExit(
        card: {'kind': 'guest'}, session: s, plate: plate, candidates: candidates, now: at(28, 10), settings: cfg);
    expect(exit(s: null)['message'], 'Khong co luot gui');
    expect(exit(s: session, plate: '30A99999')['message'], 'Sai bien so');
    expect(exit(s: session, plate: '30A99999', candidates: ['59X112345']),
        {'ok': true, 'open': true, 'message': 'Phi: 3000d', 'fee': 3000});
  });

  test('attStat + summarize: trễ, về sớm, giờ làm, quên chấm ra', () {
    const base = {'guard_id': 1, 'guard_name': 'Tuấn', 'shift_start': '2026-10-28T06:00:00Z', 'shift_end': '2026-10-28T14:00:00Z'};
    final done = {...base, 'time_in': '2026-10-28T06:12:00Z', 'time_out': '2026-10-28T13:55:00Z', 'method_out': 'finger'};
    final forgot = {...base, 'shift_start': '2026-10-29T06:00:00Z', 'shift_end': '2026-10-29T14:00:00Z',
      'time_in': '2026-10-29T06:00:00Z', 'time_out': '2026-10-29T14:00:00Z', 'method_out': 'auto'};
    expect(attStat(done), {'lateMin': 12, 'earlyMin': 5, 'workedMin': 463, 'open': false, 'missingOut': false});
    expect(attStat(forgot)['workedMin'], 0);
    expect(summarize([done, forgot]).single, {'guardId': 1, 'name': 'Tuấn', 'shifts': 2, 'workedMin': 463,
      'lateCount': 1, 'lateMin': 12, 'earlyCount': 1, 'earlyMin': 5, 'missingOut': 1});
  });

  test('nearestShift: ca gần nhất xét cả hôm trước / hôm sau, ca qua đêm (giống logic_test.dart)', () {
    const defs = [
      {'_id': 1, 'name': 'Sang', 'start_time': '06:00:00', 'end_time': '14:00:00'},
      {'_id': 2, 'name': 'Chieu', 'start_time': '14:00:00', 'end_time': '22:00:00'},
      {'_id': 3, 'name': 'Dem', 'start_time': '22:00:00', 'end_time': '06:00:00'},
    ];
    final s = nearestShift(defs, at(28, 6, 10))!;
    expect([s.def['name'], s.start, s.end], ['Sang', at(28, 6), at(28, 14)]);
    expect(nearestShift(defs, at(28, 13, 45))!.def['name'], 'Chieu');
    final dem = nearestShift(defs, at(28, 21, 50))!;
    expect([dem.def['name'], dem.end], ['Dem', at(29, 6)]);
    final night = nearestShift([{'_id': 3, 'name': 'Dem', 'start_time': '23:30', 'end_time': '07:30'}], at(29, 0, 15))!;
    expect([night.start, night.end], [at(28, 23, 30), at(29, 7, 30)]);
    expect(nearestShift([], at(28, 8)), isNull);
  });

  test('oledName lấy tên gọi, bỏ dấu', () {
    expect(oledName('Nguyễn Văn Tuấn'), 'Tuan');
    expect(oledName('Trần Đức'), 'Duc');
    expect(oledName('  Lê Thị Ưởng  '), 'Uong');
  });

  test('các ca chuyển từ logic_test.dart của app: lỗi OCR thực tế, vé tháng hết hạn lúc đang gửi, thiếu biển lúc vào', () {
    expect(samePlate('29M303658', '29Y303658'), isTrue); // Y đọc thành M
    expect(samePlate('29Y303653', '29Y303658'), isTrue); // 8 đọc thành 3
    expect(samePlate('29-y3 036.58', '29Y303658'), isTrue);
    final now = at(30, 9);
    Map card(String? until) => {'active': true, 'kind': 'monthly', 'plate': '59X112345', 'valid_until': until};
    final session = {'plate_in': '59X112345', 'time_in': at(29, 8)};
    Map exit(Map? c) => decideExit(card: c, session: session, plate: '59X112345', now: now, settings: cfg);
    expect(exit(card('2026-10-29'))['fee'], 5000); // hết hạn trong lúc gửi -> tính như vé lượt
    expect(exit(card('2026-11-29'))['fee'], 0);
    expect(decideEntry(card: card(null), hasOpenSession: false, free: 1, plate: '59X112345', now: now)['ok'], isTrue);
    expect(decideExit(card: null, session: {...session, 'plate_in': null}, plate: 'X', now: now, settings: cfg)['message'],
        'Thieu bien luc vao');
    expect(decideExit(card: null, session: session, plate: '30A999999', candidates: ['30A999998'], now: now, settings: cfg)['message'],
        'Sai bien so');
  });

  test('hạn vé tháng: cộng nối tiếp khi còn hạn, tính từ hôm nay khi hết hạn', () {
    final now = DateTime(2026, 10, 30, 9);
    expect(extendUntil(null, 1, now), '2026-11-29');
    expect(extendUntil('2026-11-15', 1, now), '2026-12-15');
    expect(extendUntil('2026-10-01', 3, now), '2027-01-29');
    expect(monthlyValid({'kind': 'monthly', 'valid_until': '2026-10-30'}, DateTime(2026, 10, 30, 23, 59)), isTrue);
    expect(monthlyValid({'kind': 'monthly', 'valid_until': '2026-10-29'}, now), isFalse);
  });

  test('cổng: vé tháng hết hạn không cho vào; thẻ báo mất bị chặn cả vào lẫn ra', () {
    final now = DateTime(2026, 10, 30, 9);
    final card = {'active': true, 'kind': 'monthly', 'plate': '59X112345', 'valid_until': '2026-10-29'};
    Map entry(Map c) => decideEntry(card: c, hasOpenSession: false, free: 5, plate: '59X112345', score: 0.95, now: now);
    expect(entry(card)['message'], 'Ve thang het han');
    expect(entry({...card, 'lost_at': DateTime.now()})['message'], 'The da bao mat');
    final exit = decideExit(card: {...card, 'lost_at': DateTime.now()}, session: {'plate_in': '59X112345', 'time_in': now},
        plate: '59X112345', now: now, settings: {'price_day': 3000, 'price_night': 5000, 'night_mark': '22:00'});
    expect([exit['ok'], exit['open']], [false, false]);
  });

  test('chỉ đường: lời chỉ dẫn và đường ra', () {
    const layout = ['#I#####O#', '#=======#', '#AA.CC..#', '#########'];
    final r = route(layout, 2, 5, 'C-02')!;
    expect(r['hint'], 'Qua cổng vào, đi thẳng 1 ô, rẽ trái đi 4 ô, ô C-02 ở bên phải');
    expect([r['path'][0], (r['path'] as List).last, (r['exitPath'] as List).last], [[0, 1], [2, 5], [0, 7]]);
    expect(layoutError(sampleLayout, ['A', 'B', 'C', 'D']), isNull);
  });

  test('JWT: ký / kiểm, sai chữ ký, hết hạn, sai audience', () {
    final t = jwtSign({'sub': 5, 'role': 'admin'}, 's', expiresIn: const Duration(minutes: 1));
    expect(jwtVerify(t, 's')['sub'], 5);
    expect(() => jwtVerify(t, 'khac'), throwsFormatException);
    expect(() => jwtVerify(jwtSign({}, 's', expiresIn: const Duration(seconds: -1)), 's'), throwsFormatException);
    final ticket = jwtSign({'uid': 'A1'}, 's', expiresIn: const Duration(minutes: 1), audience: 'bgx-ticket');
    expect(jwtVerify(ticket, 's', audience: 'bgx-ticket')['uid'], 'A1');
    expect(() => jwtVerify(t, 's', audience: 'bgx-ticket'), throwsFormatException);
    // Token do jsonwebtoken (bản Node cũ) ký vẫn hợp lệ: người dùng không bị đăng xuất khi đổi sang API Dart.
    const fromNode = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInJvbGUiOiJhZG1pbiIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjo0MTAyNDQ0ODAwfQ.'
        'vvlguveP3m1HGQeeiex0QeeqLpnl-0Ld1zv7aFSm6Iw';
    expect(jwtVerify(fromNode, 's'), {'sub': 1, 'role': 'admin', 'iat': 1700000000, 'exp': 4102444800});
  });

  test('mật khẩu băm bằng bcryptjs (bản Node cũ) vẫn đăng nhập được', () async {
    const fromNode = r'$2b$10$pnfLqvbCdp7KgnpdcjFydevkfS4E3OTk2sqzuAux/B00Qk3dK.yDK';
    expect(await checkPassword('matkhau1', fromNode), isTrue);
    expect(await checkPassword('matkhau2', fromNode), isFalse);
    expect(await checkPassword('x', 'khong-phai-hash'), isFalse);
  });
}
