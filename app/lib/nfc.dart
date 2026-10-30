import 'dart:async';
import 'dart:typed_data';

import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

/// UID thẻ dạng hex in hoa, cùng định dạng ESP32 gửi khi quẹt ở đầu đọc RC522 (VD: A1B2C3D4).
String uidHex(Uint8List id) => id.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

Future<bool> nfcAvailable() async {
  try {
    return await NfcManager.instance.checkAvailability() == NfcAvailability.enabled;
  } catch (_) {
    return false; // máy không có NFC / nền tảng không hỗ trợ (macOS)
  }
}

/// Chờ chạm thẻ RFID 13,56 MHz (MIFARE) vào mặt lưng điện thoại, trả về UID. Hết [timeout] -> null.
/// Thẻ gửi xe dùng chuẩn ISO 14443-A nên NFC của điện thoại đọc được UID giống đầu đọc RC522 ở cổng.
Future<String?> readCardUid({Duration timeout = const Duration(seconds: 30)}) async {
  final done = Completer<String?>();
  await NfcManager.instance.startSession(
    pollingOptions: {NfcPollingOption.iso14443},
    alertMessageIos: 'Chạm thẻ gửi xe vào mặt sau điện thoại',
    onDiscovered: (tag) async {
      final id = NfcTagAndroid.from(tag)?.id ?? MiFareIos.from(tag)?.identifier;
      if (!done.isCompleted) done.complete(id == null ? null : uidHex(id));
    },
  );
  try {
    return await done.future.timeout(timeout, onTimeout: () => null);
  } finally {
    await NfcManager.instance.stopSession();
  }
}

Future<void> cancelNfc() async {
  try {
    await NfcManager.instance.stopSession();
  } catch (_) {}
}
