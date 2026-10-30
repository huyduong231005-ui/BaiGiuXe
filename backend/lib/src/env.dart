import 'dart:io';

/// Biến môi trường, thêm các dòng KEY=VALUE trong .env nếu có (chạy thử trên máy). Biến của hệ thống được ưu tiên.
/// Lưu ý: TZ trong .env không đổi được múi giờ của tiến trình đang chạy, đặt TZ ở hệ thống / Render.
Map<String, String> loadEnv() {
  final file = File('.env');
  final fromFile = <String, String>{};
  if (file.existsSync()) {
    for (final line in file.readAsLinesSync()) {
      final i = line.indexOf('=');
      if (line.trimLeft().startsWith('#') || i < 1) continue;
      fromFile[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
  }
  return {...fromFile, ...Platform.environment};
}
