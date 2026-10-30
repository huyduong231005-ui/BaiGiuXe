import 'package:bai_giu_xe_api/src/db.dart';
import 'package:bai_giu_xe_api/src/rules.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Ctx ctx;
  late String manager, khach, khac;
  setUpAll(() async {
    ctx = await startApp();
    manager = await loginAs(ctx, 'manager', 'quanly');
    khach = await loginAs(ctx, 'customer', 'khach');
    khac = await loginAs(ctx, 'customer', 'khac');
  });
  tearDownAll(() => ctx.close());

  test('khách gửi đơn vé tháng -> sửa -> quản lý duyệt, gán thẻ -> thẻ hiện trong app khách', () async {
    // Form đăng ký vé tháng / sơ đồ của khách cần bảng giá loại xe; thêm loại xe vẫn chỉ quản lý.
    expect((await ctx.call('GET', '/vehicle-types', token: khach)).body, isNotEmpty);
    expect((await ctx.call('POST', '/vehicle-types', token: khach, body: {'code': 'ebike'})).status, 403);
    final bad =await ctx.call('POST', '/me/requests', token: khach, body: {'plate': '59', 'ownerName': 'An', 'months': 1, 'apartment': 'A1-12.05'});
    expect(bad.status, 400);
    final r0 = await ctx.call('POST', '/me/requests', token: khach, body: {'plate': '59x1-123.45', 'ownerName': 'An', 'months': 1});
    expect(r0.status, 400); // thiếu căn hộ
    final r = await ctx.call('POST', '/me/requests', token: khach,
        body: {'plate': '59x1-123.45', 'ownerName': 'An', 'months': 1, 'apartment': 'A1-12.05'});
    expect([r.status, r.body['plate'], r.body['status']], [201, '59X112345', 'pending']);
    final e = await ctx.call('PATCH', '/me/requests/${r.body['id']}', token: khach,
        body: {'plate': '59X112345', 'ownerName': 'Nguyễn An', 'months': 3, 'apartment': 'a1-12.05'});
    expect(e.body['months'], 3);
    expect((await ctx.call('PATCH', '/me/requests/${r.body['id']}', token: khac,
        body: {'plate': '59X112345', 'ownerName': 'X', 'months': 1, 'apartment': 'B2'})).status, 409);

    // Khách không vào được API của quản lý, quản lý không vào được /me/requests
    expect((await ctx.call('GET', '/requests', token: khach)).status, 403);
    expect((await ctx.call('GET', '/me/requests', token: manager)).status, 403);

    final list = await ctx.call('GET', '/requests?status=pending', token: manager);
    expect(list.body[0]['username'], 'khach');
    expect((await ctx.call('POST', '/requests/${r.body['id']}/approve', token: manager, body: {})).status, 400);
    final ok = await ctx.call('POST', '/requests/${r.body['id']}/approve', token: manager, body: {'cardUid': 'a1b2c3d4'});
    expect(ok.status, 200);
    expect([ok.body['card']['uid'], ok.body['card']['kind'], ok.body['card']['plate'], ok.body['request']['status']],
        ['A1B2C3D4', 'monthly', '59X112345', 'approved']);
    expect(ok.body['card']['valid_until'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect((await ctx.call('POST', '/requests/${r.body['id']}/approve', token: manager, body: {'cardUid': 'A1B2C3D4'})).status, 409);

    final cards = await ctx.call('GET', '/me/cards', token: khach);
    expect([cards.body.length, cards.body[0]['valid']], [1, true]);
    expect((await ctx.call('GET', '/me/cards', token: khac)).body.length, 0);
  });

  test('gia hạn thẻ đang dùng: hạn mới nối tiếp hạn cũ; thẻ của khách khác thì không gán được', () async {
    await Card.updateOne({'uid': 'A1B2C3D4'}, {'valid_until': ymd(DateTime.now().add(const Duration(days: 10)))});
    final r = await ctx.call('POST', '/me/requests', token: khach,
        body: {'plate': '59X112345', 'ownerName': 'An', 'months': 1, 'cardUid': 'A1B2C3D4', 'apartment': 'A1-12.05'});
    expect((await ctx.call('POST', '/me/requests', token: khac,
        body: {'plate': '59X112345', 'ownerName': 'X', 'months': 1, 'cardUid': 'A1B2C3D4', 'apartment': 'B2'})).status, 400);
    final before = (await Card.findOne({'uid': 'A1B2C3D4'}))!['valid_until'];
    final ok = await ctx.call('POST', '/requests/${r.body['id']}/approve', token: manager, body: {});
    expect(ok.body['card']['valid_until'], extendUntil(before, 1));

    final r2 = await ctx.call('POST', '/me/requests', token: khac,
        body: {'plate': '30A99999', 'ownerName': 'Bình', 'months': 1, 'apartment': 'B2-03.01'});
    expect((await ctx.call('POST', '/requests/${r2.body['id']}/approve', token: manager, body: {'cardUid': 'A1B2C3D4'})).status, 409);
    final rej = await ctx.call('POST', '/requests/${r2.body['id']}/reject', token: manager, body: {'reply': 'Bãi hết chỗ vé tháng'});
    expect([rej.body['status'], rej.body['reply']], ['rejected', 'Bãi hết chỗ vé tháng']);
    expect((await ctx.call('DELETE', '/me/requests/${r2.body['id']}', token: khac)).status, 409); // đã xử lý thì không huỷ
  });

  test('báo mất thẻ, mã QR vé, lịch sử và ảnh xe của chính mình', () async {
    await Session.insert({'card_uid': 'A1B2C3D4', 'plate_in': '59X112345',
      'img_in': 'in/2026-10-30/1761800000000_A1B2C3D4.jpg', 'time_in': ago(2)});
    final mine = (await ctx.call('GET', '/me/cards', token: khach)).body[0];
    expect([mine['parked_plate'], mine['fee_now']], ['59X112345', 0]); // vé tháng còn hạn: miễn phí

    final qr = await ctx.call('GET', '/me/cards/A1B2C3D4/qr', token: khach);
    expect((qr.body['qr'] as String).contains('A1B2C3D4'), isFalse); // mã QR không lộ UID thẻ
    expect((await ctx.call('GET', '/me/cards/A1B2C3D4/qr', token: khac)).status, 404);
    final scan = await ctx.call('GET', '/sessions/by-ticket?qr=${Uri.encodeQueryComponent(qr.body['qr'])}', token: manager);
    expect([scan.body['cardUid'], scan.body['matches'][0]['plate_in']], ['A1B2C3D4', '59X112345']);
    expect((await ctx.call('GET', '/sessions/by-ticket?qr=gia-mao', token: manager)).status, 400);

    final hist = await ctx.call('GET', '/me/sessions', token: khach);
    expect(hist.body.length, 1);
    final img = await ctx.call('GET', '/me/plates/url?path=in/2026-10-30/1761800000000_A1B2C3D4.jpg', token: khach);
    expect(img.status, 200);
    expect((await ctx.call('GET', '/me/plates/url?path=in/2026-10-30/1761800000000_A1B2C3D4.jpg', token: khac)).status, 403);

    expect((await ctx.call('POST', '/me/cards/A1B2C3D4/lost', token: khac)).status, 404);
    final lost = await ctx.call('POST', '/me/cards/A1B2C3D4/lost', token: khach);
    expect([lost.body['active'], lost.body['lost_at'] != null], [false, true]);
    // Quản lý mở lại khi khách tìm thấy thẻ
    final back = await ctx.call('PATCH', '/cards/A1B2C3D4', token: manager, body: {'active': true, 'lost': false});
    expect([back.body['active'], back.body['lost_at'], back.body['valid_until']], [true, null, mine['valid_until']]);
  });

  test('admin tạo tài khoản đã kích hoạt; thông tin bãi công khai cho bản đồ', () async {
    final admin = await loginAs(ctx, 'admin', 'admin1');
    final u = await ctx.call('POST', '/admin/users', token: admin,
        body: {'email': 'bv2@test.vn', 'username': 'baove2', 'password': 'matkhau1', 'role': 'guard', 'fullName': 'Bảo vệ 2'});
    expect([u.status, u.body['role'], u.body['active']], [201, 'guard', true]);
    expect((await ctx.call('POST', '/admin/users', token: manager, body: {})).status, 403);

    await ctx.call('PUT', '/settings', token: manager, body: {'capacity': 50, 'priceDay': 3000, 'priceNight': 5000,
      'nightMark': '22:00', 'lotName': 'Bãi xe HUTECH', 'address': '475A Điện Biên Phủ', 'lat': 10.8017, 'lng': 106.7149});
    final lot = await ctx.call('GET', '/lot');
    expect([lot.body['name'], lot.body['lat'], lot.body['free']], ['Bãi xe HUTECH', 10.8017, 49]);
    expect((await ctx.call('PUT', '/settings', token: manager,
        body: {'capacity': 50, 'priceDay': 3000, 'priceNight': 5000, 'nightMark': '22:00', 'lat': 200, 'lng': 1})).status, 400);
  });
}
