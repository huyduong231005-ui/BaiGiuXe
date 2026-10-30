import 'dart:io';

import 'package:bai_giu_xe_api/src/app.dart';
import 'package:bai_giu_xe_api/src/db.dart';
import 'package:bai_giu_xe_api/src/deps.dart';
import 'package:bai_giu_xe_api/src/env.dart';
import 'package:bai_giu_xe_api/src/mail.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

const _required = ['MONGODB_URI', 'JWT_SECRET', 'PLATE_TOKEN', 'GOOGLE_CLIENT_ID', 'BREVO_API_KEY', 'MAIL_FROM'];

Future<void> main() async {
  final env = loadEnv();
  final missing = _required.where((k) => (env[k] ?? '').isEmpty).toList();
  if (missing.isNotEmpty) throw StateError('Thiếu biến môi trường: ${missing.join(', ')}');

  await connect(env['MONGODB_URI']!);
  await initDb();
  final app = createApp(Deps(
    jwtSecret: env['JWT_SECRET']!,
    plateToken: env['PLATE_TOKEN']!,
    sendMail: brevoMailer(apiKey: env['BREVO_API_KEY']!, from: env['MAIL_FROM']!),
    verifyGoogle: googleVerifier(env['GOOGLE_CLIENT_ID']!),
  ));
  final port = int.parse(env['PORT'] ?? '3000');
  await shelf_io.serve(app, InternetAddress.anyIPv4, port);
  print('API chạy ở cổng $port, múi giờ ${DateTime.now().timeZoneName}');
}
