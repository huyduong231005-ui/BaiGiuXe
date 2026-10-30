import 'package:bai_giu_xe_api/src/db.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Ctx ctx;
  late String token;
  setUpAll(() async {
    ctx = await startApp();
    token = await loginAs(ctx, 'manager', 'quanly');
  });
  tearDownAll(() => ctx.close());

  test('thẻ: thêm, chuẩn hoá biển, vé tháng bắt buộc biển, sửa, tìm, xe đang trong bãi thì chưa xoá được thẻ', () async {
    final bad = await ctx.call('POST', '/cards', token: token, body: {'uid': 'A1B2C3D4', 'kind': 'monthly'});
    expect([bad.status, bad.body['message']], [400, 'Vé tháng cần biển số']);
    expect((await ctx.call('POST', '/cards', token: token, body: {'uid': 'xyz'})).status, 400);

    final c = await ctx.call('POST', '/cards', token: token, body: {'uid': 'a1b2c3d4', 'kind': 'monthly', 'plate': '59x1-123.45', 'owner': 'An'});
    expect(c.status, 201);
    expect([c.body['uid'], c.body['plate']], ['A1B2C3D4', '59X112345']);
    expect((await ctx.call('POST', '/cards', token: token, body: {'uid': 'A1B2C3D4'})).status, 409);

    final p = await ctx.call('PATCH', '/cards/A1B2C3D4', token: token, body: {'active': false});
    expect([p.body['active'], p.body['kind']], [false, 'monthly']);
    expect((await ctx.call('GET', '/cards?q=an', token: token)).body.length, 1);

    await Session.insert({'card_uid': 'A1B2C3D4', 'plate_in': '59X112345'});
    final del = await ctx.call('DELETE', '/cards/A1B2C3D4', token: token);
    expect([del.status, (del.body['message'] as String).contains('đang trong bãi')], [409, true]);
    // Thẻ đã có lịch sử nhưng xe đã ra: xoá được, lịch sử vẫn còn
    await ctx.call('POST', '/cards', token: token, body: {'uid': '33333333'});
    await Session.insert({'card_uid': '33333333', 'plate_in': '51F33333', 'time_in': DateTime.parse('2025-01-01T08:00:00+07:00'),
      'time_out': DateTime.parse('2025-01-01T10:00:00+07:00'), 'fee': 5000, 'parked': false});
    expect((await ctx.call('DELETE', '/cards/33333333', token: token)).status, 204);
    expect((await ctx.call('GET', '/sessions?plate=51F33333&date=2025-01-01', token: token)).body['count'], 1);
  });

  test('số chỗ trống công khai, lịch sử theo ngày + doanh thu, phí tạm tính', () async {
    await ctx.call('POST', '/cards', token: token, body: {'uid': '11111111'});
    await Session.insert({'card_uid': '11111111', 'plate_in': '30A99999', 'time_in': ago(3), 'time_out': ago(1),
      'fee': 3000, 'parked': false});
    expect((await ctx.call('GET', '/status')).body, {'capacity': 50, 'occupied': 1, 'free': 49});

    final h = await ctx.call('GET', '/sessions?plate=30a-999', token: token);
    expect([h.body['count'], h.body['revenue']], [1, 3000]);
    final open = await ctx.call('GET', '/sessions?open=true', token: token);
    expect(open.body['sessions'][0]['plate_in'], '59X112345');
    expect((await ctx.call('GET', '/sessions?date=30-10-2026', token: token)).status, 400);

    expect((await ctx.call('GET', '/stats/revenue', token: token)).body['total'], 3000);

    final q = await ctx.call('POST', '/fees/quote', body: {'timeIn': '2026-10-28T13:00:00Z', 'timeOut': '2026-10-29T00:00:00Z'});
    expect([q.body['fee'], q.body['nights']], [10000, 1]); // xe máy 20:00 -> 07:00 giờ VN qua mốc 22:00: 1 giá đêm
  });

  test('cho xe ra khi mất thẻ: đóng lượt, tính phí, tạo lệnh mở cổng', () async {
    await ctx.call('POST', '/cards', token: token, body: {'uid': '22222222'});
    final s = await Session.insert({'card_uid': '22222222', 'plate_in': '51F00001', 'time_in': ago(2)});
    final fee = motorbikeFeeSince(s['time_in']); // giá ngày xe máy 5000 (10000 nếu đã qua mốc đêm)
    expect((await ctx.call('GET', '/sessions/${s['id']}/fee', token: token)).body['fee'], fee);
    final r = await ctx.call('POST', '/sessions/${s['id']}/release', token: token);
    expect([r.status, r.body['fee']], [200, fee]);
    expect((await ctx.call('POST', '/sessions/${s['id']}/release', token: token)).status, 409);
    final ev = (await ctx.call('GET', '/events?limit=1', token: token)).body[0];
    expect([ev['kind'], ev['status'], ev['gate']], ['open_cmd', 'pending', 'out']);
  });

  test('mở cổng từ API và thẻ vừa quẹt cho màn thêm thẻ', () async {
    expect((await ctx.call('POST', '/gate/open', token: token)).status, 201);
    final since = Uri.encodeQueryComponent(DateTime.now().toUtc().toIso8601String());
    expect((await ctx.call('GET', '/scans/latest?since=$since', token: token)).body, isNull);
    await GateEvent.insert({'gate': 'in', 'kind': 'scan', 'uid': '99AABBCC', 'status': 'denied'});
    final scan = await ctx.call('GET', '/scans/latest?since=$since', token: token);
    expect([scan.body['uid'], scan.body['registered']], ['99AABBCC', false]);
  });

  test('cài đặt: kiểm dữ liệu rồi lưu', () async {
    final bad = await ctx.call('PUT', '/settings', token: token, body: {'capacity': 0, 'priceDay': 1, 'priceNight': 1, 'nightMark': '22:00'});
    expect(bad.status, 400);
    final r = await ctx.call('PUT', '/settings', token: token, body: {'capacity': 80, 'priceDay': 4000, 'priceNight': 6000, 'nightMark': '21:30'});
    expect([r.body['capacity'], r.body['night_mark']], [80, '21:30:00']);
    expect((await ctx.call('GET', '/status')).body['capacity'], 80);
  });

  test('trang chủ, /docs và /openapi.json vẫn phục vụ được', () async {
    expect((await ctx.call('GET', '/health')).body, {'ok': true});
    expect((await ctx.call('GET', '/openapi.json')).body['openapi'], '3.0.3');
  });
}
