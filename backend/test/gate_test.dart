import 'package:bai_giu_xe_api/src/db.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const img = 'in/2026-10-30/1761800000000_A1B2C3D4.jpg';

void main() {
  late Ctx ctx;
  late String token;
  late int guardId;
  setUpAll(() async {
    ctx = await startApp();
    token = await loginAs(ctx, 'manager', 'camera');
    await ctx.call('POST', '/cards', token: token, body: {'uid': 'A1B2C3D4'});
    await ctx.call('POST', '/cards', token: token, body: {'uid': 'B1B2C3D4', 'kind': 'monthly', 'plate': '30A99999'});
    guardId = (await ctx.call('POST', '/guards', token: token, body: {'name': 'Nguyễn Văn Tuấn', 'pin': '2468'})).body['id'];
  });
  tearDownAll(() => ctx.close());

  Future<Res> scan(Map body) => ctx.call('POST', '/gate/scan', token: token, body: body);

  test('quẹt thẻ: API kiểm tra, mở / đóng lượt gửi, ghi nhật ký, trả 2 dòng OLED và chỗ trống', () async {
    expect((await scan({'gate': 'x', 'uid': 'A1B2C3D4'})).status, 400);
    expect((await scan({'gate': 'in', 'uid': 'FFFFFFFF', 'plate': '59X112345', 'score': 0.9})).body['message'], 'The chua dang ky');
    expect((await scan({'gate': 'in', 'uid': 'A1B2C3D4', 'plate': null})).body['message'], 'Khong doc duoc bien');
    expect((await scan({'gate': 'in', 'uid': 'A1B2C3D4', 'plate': '59X112345', 'score': 0.5})).body['message'], 'Bien mo, quet lai');
    expect((await scan({'gate': 'in', 'uid': 'B1B2C3D4', 'plate': '59X112345', 'score': 0.9})).body['message'], 'Sai xe ve thang');

    final vao = (await scan({'gate': 'in', 'uid': 'a1b2c3d4', 'plate': '59x1-123.45', 'score': 0.95, 'img': img})).body;
    expect([vao['ok'], vao['l1'], vao['l2'], vao['status']['free']], [true, '59X112345', 'Moi vao', 49]);
    expect((await scan({'gate': 'in', 'uid': 'A1B2C3D4', 'plate': '59X112345', 'score': 0.95})).body['message'], 'The dang gui xe');
    // Biển đã trong bãi thì thẻ khác cũng không đưa vào được
    expect((await scan({'gate': 'in', 'uid': 'B1B2C3D4', 'plate': '59X112345', 'score': 0.95})).body['message'], 'Xe da o trong bai');

    expect((await scan({'gate': 'out', 'uid': 'A1B2C3D4', 'plate': '30A11111'})).body['message'], 'Sai bien so');
    final ra = (await scan({'gate': 'out', 'uid': 'A1B2C3D4', 'plate': '59X112346', 'candidates': ['59X112345']})).body;
    final fee = motorbikeFeeSince(DateTime.now().subtract(const Duration(seconds: 1))); // xe vào vài giây trước
    expect([ra['ok'], ra['open'], ra['fee'], ra['l2'], ra['status']['free']], [true, true, fee, 'Phi: ${fee}d', 50]);
    expect((await scan({'gate': 'out', 'uid': 'A1B2C3D4', 'plate': '59X112345'})).body['message'], 'Khong co luot gui');

    final s = (await ctx.call('GET', '/sessions?plate=59X112345', token: token)).body['sessions'][0];
    expect([s['img_in'], s['fee'], s['plate_out']], [img, fee, '59X112346']);
    final last = (await ctx.call('GET', '/events?limit=1', token: token)).body[0];
    expect([last['kind'], last['status'], last['uid']], ['scan', 'denied', 'A1B2C3D4']);
  });

  test('mã xoay vòng: thẻ nhận mã đầu, mã khớp thì xoay tiếp, thẻ chép mang mã cũ bị từ chối và khoá thẻ', () async {
    String t(String c) => c * 32;
    await ctx.call('POST', '/cards', token: token, body: {'uid': 'C1C2C3C4'});
    Future<Map> go(String gate, String? tok, String ntok) async => (await scan(
        {'gate': gate, 'uid': 'C1C2C3C4', 'plate': '51F12345', 'score': 0.95, 'tok': tok, 'ntok': ntok})).body;

    expect((await go('in', t('0'), t('A')))['ok'], true); // thẻ chưa có mã: nhận mã A
    expect((await go('out', t('A'), t('B')))['ok'], true); // đúng mã A -> xoay sang B
    // Thẻ chép từ lúc thẻ còn mã A (thẻ thật đã sang B)
    final clone = await go('in', t('A'), t('C'));
    expect([clone['ok'], clone['l2']], [false, 'The nghi sao chep']);
    final card = ((await ctx.call('GET', '/cards?q=C1C2', token: token)).body as List).first;
    expect([card['active'], card.containsKey('tok')], [false, false]); // khoá thẻ, không lộ mã ra API
    // Không gửi mã (quẹt thử, NFC, ESP32 bản cũ): không kiểm tra
    expect((await scan({'gate': 'in', 'uid': 'C1C2C3C4', 'plate': '51F12345', 'score': 0.95})).body['message'],
        isNot('The nghi sao chep'));
  });

  test('bảo vệ mở tay: sai PIN bị từ chối, đúng PIN đóng lượt bị từ chối gần đây kèm tên bảo vệ', () async {
    expect((await ctx.call('POST', '/gate/auth', token: token, body: {'pin': '0000'})).body['ok'], false);
    final enroll = (await ctx.call('POST', '/gate/auth', token: token, body: {'pin': '2468', 'enroll': true})).body;
    expect([enroll['ok'], enroll['guardId']], [true, guardId]);

    final timeIn = ago(1);
    final fee = motorbikeFeeSince(timeIn);
    await Session.insert({'card_uid': 'A1B2C3D4', 'plate_in': '59X112345', 'time_in': timeIn});
    final r = (await ctx.call('POST', '/gate/auth', token: token,
        body: {'pin': '2468', 'denied': {'uid': 'A1B2C3D4', 'plate': '59X112345'}})).body;
    expect(r['message'], matches(RegExp(r'PIN bao ve #\d+ \| the A1B2C3D4 \| Phi: ' '${fee}d')));
    final s = ((await ctx.call('GET', '/sessions?plate=59X112345', token: token)).body['sessions'] as List).last; // lượt vào 1 giờ trước
    expect([s['override_name'], s['fee']], ['Nguyễn Văn Tuấn', fee]);
  });

  test('đăng ký vân tay rồi chấm công bằng vân tay: vào ca, ra ca', () async {
    expect((await ctx.call('POST', '/gate/enrolled', token: token, body: {'id': 999})).status, 404);
    expect((await ctx.call('POST', '/gate/enrolled', token: token, body: {'id': guardId})).body['ok'], true);
    expect((await ctx.call('POST', '/gate/punch', token: token, body: {'finger': 77})).body,
        {'ok': false, 'pinWrong': false, 'l1': 'KHONG RO', 'l2': 'Van tay #77 chua gan'});

    final vao = (await ctx.call('POST', '/gate/punch', token: token, body: {'finger': guardId})).body;
    expect([vao['ok'], vao['l1']], [true, 'VAO CA']);
    expect(vao['l2'], matches(RegExp(r'^Tuan \d\d:\d\d')));
    final ra = (await ctx.call('POST', '/gate/punch', token: token, body: {'pin': '2468'})).body;
    expect(ra['l1'], 'RA CA');
    final att = (await ctx.call('GET', '/attendance', token: token)).body['records'][0];
    expect([att['method_in'], att['method_out'], att['open']], ['finger', 'pin', false]);
  });

  test('lệnh mở cổng từ app quản lý: ĐT cổng ra hỏi định kỳ, lệnh quá cũ bị bỏ', () async {
    final cmd = (await ctx.call('POST', '/gate/open', token: token)).body;
    await GateEvent.insert({'gate': 'out', 'kind': 'open_cmd', 'created_at': ago(1)});
    expect([for (final c in (await ctx.call('GET', '/gate/commands', token: token)).body) c['id']], [cmd['id']]);
    expect((await ctx.call('POST', '/gate/commands/${cmd['id']}/done', token: token)).body['status'], 'done');
    expect((await ctx.call('GET', '/gate/commands', token: token)).body, []);
    expect((await ctx.call('POST', '/gate/emergency', token: token, body: {'on': true})).body['message'], 'Bat khan cap');
  });

  test('API cổng chỉ cho quản lý / admin', () async {
    final guard = await loginAs(ctx, 'guard', 'baove');
    expect((await ctx.call('POST', '/gate/scan', token: guard, body: {'gate': 'in', 'uid': 'A1B2C3D4'})).status, 403);
    expect((await ctx.call('GET', '/gate/commands')).status, 401);
  });
}
