// Cấp quyền admin cho 1 tài khoản đã đăng ký: dart run bin/make_admin.dart <username>
import 'package:bai_giu_xe_api/src/db.dart';
import 'package:bai_giu_xe_api/src/env.dart';

Future<void> main(List<String> args) async {
  final username = args.isEmpty ? '' : args[0].toLowerCase();
  if (username.isEmpty) throw StateError('Cách dùng: dart run bin/make_admin.dart <username>');
  await connect(loadEnv()['MONGODB_URI']!);
  final user = await User.findOneAndUpdate({'username': username}, {'role': 'admin', 'active': true});
  print(user != null ? 'Đã cấp quyền admin cho $username' : 'Không có tài khoản $username');
  await db.close();
}
