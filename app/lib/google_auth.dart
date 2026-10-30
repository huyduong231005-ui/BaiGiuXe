import 'package:google_sign_in/google_sign_in.dart';

import 'api.dart';

// google_sign_in v7: initialize() phải gọi ĐÚNG 1 lần trước mọi hàm khác, gọi lại là "undefined behavior".
Future<void>? _ready;

Future<void> _init() => _ready ??= GoogleSignIn.instance.initialize(serverClientId: googleServerClientId).catchError((Object e) {
      _ready = null; // lỗi thì lần sau thử lại
      throw e;
    });

/// Mở chọn tài khoản Google, trả về idToken để backend tự xác thực. Trả về null nếu người dùng huỷ.
Future<String?> googleIdToken() async {
  await _init();
  final GoogleSignInAccount account;
  try {
    account = await GoogleSignIn.instance.authenticate();
  } on GoogleSignInException catch (e) {
    if (e.code == GoogleSignInExceptionCode.canceled) return null;
    throw ApiException('Đăng nhập Google lỗi: ${e.description ?? e.code.name}');
  }
  final idToken = account.authentication.idToken;
  if (idToken == null) throw ApiException('Google không trả về idToken');
  return idToken;
}

/// Thoát tài khoản Google để lần sau chọn được tài khoản khác. Chưa từng dùng Google thì bỏ qua.
Future<void> googleSignOut() async {
  final ready = _ready;
  if (ready == null) return;
  try {
    await ready;
    await GoogleSignIn.instance.signOut();
  } on Object {
    // đăng xuất Google lỗi không được chặn việc đăng xuất khỏi app
  }
}
