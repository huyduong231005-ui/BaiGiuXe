import 'dart:convert';

import 'package:bai_giu_xe/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

void main() {
  const user = {'id': 1, 'username': 'admin', 'email': 'a@b.vn', 'fullName': 'Huy', 'role': 'admin', 'guardId': null};

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('OTP đăng nhập -> lưu token, các lần gọi sau gửi kèm Bearer; mở lại app vẫn còn phiên', () async {
    final auth = <String?>[];
    final a = Api(
      client: MockClient((req) async {
        auth.add(req.headers['authorization']);
        return req.url.path == '/auth/login/verify' ? _json({'token': 'jwt-1', 'user': user}) : _json({'free': 3});
      }),
    );
    final prefs = await SharedPreferences.getInstance();
    a.restore(prefs);
    final u = await a.verifyLogin('admin', '123456');
    expect(u.isStaff, isTrue);
    expect(a.session.value?.displayName, 'Huy');
    await a.get('/status');
    expect(auth, [null, 'Bearer jwt-1']);

    final reopened = Api()..restore(prefs);
    expect(reopened.session.value?.username, 'admin');
  });

  test('lỗi trả về message tiếng Việt của API; 401 thì đăng xuất', () async {
    final a = Api(
      client: MockClient((req) async => req.url.path == '/auth/login/verify'
          ? _json({'token': 'jwt-1', 'user': user})
          : _json({'message': 'Phiên đăng nhập không hợp lệ hoặc đã hết hạn'}, 401)),
    );
    a.restore(await SharedPreferences.getInstance());
    await a.verifyLogin('admin', '123456');
    await expectLater(
      a.get('/sessions'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Phiên đăng nhập không hợp lệ hoặc đã hết hạn')),
    );
    expect(a.session.value, isNull);
  });
}
