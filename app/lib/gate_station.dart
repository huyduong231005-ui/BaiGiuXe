import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'esp_link.dart';
import 'logic.dart';

const plateToken = String.fromEnvironment('PLATE_TOKEN');

/// Gửi ảnh lên Plate Recognizer, trả về kết quả tốt nhất (plate, score...) hoặc null nếu không thấy biển.
Future<Rec?> recognize(Uint8List jpg) async {
  // ponytail: token nằm trong file build; chuyển sang Edge Function proxy nếu phát hành app ra ngoài.
  final req = http.MultipartRequest('POST', Uri.parse('https://api.platerecognizer.com/v1/plate-reader/'))
    ..headers['Authorization'] = 'Token $plateToken'
    ..fields['regions'] = 'vn'
    ..files.add(http.MultipartFile.fromBytes('upload', jpg, filename: 'shot.jpg'));
  final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 5)));
  if (res.statusCode != 200 && res.statusCode != 201) {
    throw Exception('PlateRecognizer ${res.statusCode}: ${res.body}');
  }
  final results = jsonDecode(res.body)['results'] as List;
  return results.isEmpty ? null : results.first as Rec;
}

/// Vùng giữa ảnh (quanh khung ngắm) gửi đi OCR, theo tỉ lệ khung hình.
/// Đo thực tế: ảnh gốc 993KB -> 2,5s; vùng cắt 79KB -> 1,4s, độ tin cậy còn cao hơn.
/// ponytail: nới rộng vùng này nếu biển hay nằm lệch khỏi khung ngắm.
const ocrCrop = (x: 0.15, y: 0.33, w: 0.70, h: 0.34);

Uint8List cropForOcr(Uint8List jpg) {
  final im = img.bakeOrientation(img.decodeJpg(jpg)!);
  final c = img.copyCrop(im,
      x: (im.width * ocrCrop.x).round(),
      y: (im.height * ocrCrop.y).round(),
      width: (im.width * ocrCrop.w).round(),
      height: (im.height * ocrCrop.h).round());
  return img.encodeJpg(c, quality: 85);
}

Future<String?> readPlate(Uint8List jpg) async {
  Uint8List small;
  try {
    small = await compute(cropForOcr, jpg); // isolate riêng: giải mã JPEG không làm giật giao diện
  } catch (e) {
    debugPrint('[ocr] cat anh loi, gui ca anh: $e');
    small = jpg;
  }
  final r = await recognize(small);
  return r == null ? null : normPlate(r['plate'] as String);
}

/// Gọi một lần khi mở camera: camera gắn cố định ở cổng nên lấy nét + đo sáng liên tục vào giữa khung
/// (nơi đặt biển số) là đủ, không cần lấy nét lại trước mỗi lần chụp. Tắt flash để khỏi chờ đèn đo sáng.
Future<void> setupGateCamera(CameraController camera) async {
  try {
    await camera.setFlashMode(FlashMode.off);
    if (camera.value.focusPointSupported) await camera.setFocusPoint(const Offset(0.5, 0.5));
    if (camera.value.exposurePointSupported) await camera.setExposurePoint(const Offset(0.5, 0.5));
  } on CameraException catch (e) {
    debugPrint('[camera] khong dat duoc flash/diem lay net: $e'); // vẫn chụp được với chế độ tự động
  }
}

Future<Uint8List> shoot(CameraController camera) async => (await camera.takePicture()).readAsBytes();

/// Vai trò camera của một cổng: nhận sự kiện từ ESP32 qua BLE, chụp + đọc biển, quyết định,
/// trả kết quả cho ESP32 qua BLE rồi mới ghi Supabase (không nằm trên đường chờ của cổng).
class GateStation {
  GateStation(this.gate, this.camera, this.link);

  /// Bảo vệ mở tay chỉ đóng lượt gửi của lần bị từ chối gần đây (tránh đóng nhầm xe khác).
  static const deniedRefWindow = Duration(seconds: 60);

  final String gate; // 'in' | 'out' | 'both' (1 điện thoại cho cả 2 cổng)
  final CameraController camera;
  final EspLink link;
  final db = Supabase.instance.client;
  ValueNotifier<String> get status => link.status;
  final last = ValueNotifier<String>('Chua co xe');
  final busy = ValueNotifier<bool>(false); // true trong lúc xử lý một lượt quẹt thẻ

  StreamSubscription<Rec>? _sub;
  RealtimeChannel? _openCh;
  Future<void> _queue = Future.value(); // camera chỉ chụp được tuần tự
  ({String uid, String? plate, String path, DateTime at})? _lastDenied;

  void start() {
    link.onConnected = _syncEsp;
    // Mọi điện thoại đều nhận mọi bản tin; mỗi cổng chỉ xử lý bản tin có g == cổng của mình.
    _sub = link.events
        .where((ev) => gate == 'both' || ev['g'] == gate)
        .listen((ev) => _queue = _queue.then((_) => _handle(ev)));
    if (gate != 'in') {
      // Nút "Mở cổng ra" trên app Quản lý -> gate_events(open_cmd) -> ĐT cổng ra -> BLE -> ESP32.
      _openCh = db
          .channel('open-cmd')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'gate_events',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'kind', value: 'open_cmd'),
            callback: (p) => _openFromApp(p.newRecord),
          )
          .subscribe();
    }
    link.start();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    if (_openCh != null) await db.removeChannel(_openCh!);
    await link.stop();
  }

  /// Vừa kết nối: chỉnh giờ DS3231 theo điện thoại + gửi số chỗ trống.
  Future<void> _syncEsp() async {
    try {
      final now = DateTime.now();
      await link.send({'t': 'time', 'ts': now.millisecondsSinceEpoch ~/ 1000 + now.timeZoneOffset.inSeconds});
      await _sendStatus();
    } catch (e) {
      last.value = 'Dong bo ESP32 loi: $e';
    }
  }

  Future<void> _sendStatus() async {
    final st = await db.from('parking_status').select().single();
    await link.send({'t': 'st', 'free': st['free'], 'cap': st['capacity']});
  }

  Future<void> _log(String g, Rec row) => db.from('gate_events').insert({'gate': g, ...row});

  Future<void> _handle(Rec ev) async {
    try {
      switch (ev['t']) {
        case 'scan':
          await _scanGuarded(ev);
        case 'auth':
          await _auth(ev);
        case 'emg':
          await _log('out', {'kind': 'emergency', 'status': 'done', 'message': ev['on'] == true ? 'Bat khan cap' : 'Tat khan cap'});
      }
    } catch (e) {
      last.value = 'Loi (${ev['t']}): $e';
    }
  }

  Future<void> _scanGuarded(Rec ev) async {
    busy.value = true;
    try {
      await _scan(ev);
    } catch (e) {
      last.value = 'Loi: $e';
      await link.send({'t': 'res', 'id': ev['id'], 'ok': false, 'open': false, 'l1': 'TU CHOI', 'l2': 'Loi he thong'});
    } finally {
      busy.value = false;
    }
  }

  Future<void> _scan(Rec ev) async {
    final uid = ev['uid'] as String;
    final g = ev['g'] as String; // cổng của lượt quẹt (vai trò 'both' xử lý cả 2 cổng)
    final sw = Stopwatch()..start();
    // Truy vấn DB chạy song song với chụp + OCR. Postgrest chỉ gửi request khi được then/await,
    // nên gọi .then ngay để request bắt đầu luôn.
    final cardF = db.from('cards').select().eq('uid', uid).maybeSingle().then((r) => r);
    final openF = db.from('sessions').select().eq('card_uid', uid).isFilter('time_out', null).maybeSingle().then((r) => r);
    final extraF = (g == 'in' ? db.from('parking_status').select().single() : db.from('settings').select().single())
        .then((r) => r);

    final bytes = await shoot(camera);
    final tShot = sw.elapsedMilliseconds;
    final now = DateTime.now();
    final path = '$g/${now.toIso8601String().substring(0, 10)}/${now.millisecondsSinceEpoch}_$uid.jpg';

    String? plate;
    try {
      plate = await readPlate(bytes);
    } catch (e) {
      last.value = 'OCR loi: $e'; // plate = null -> decide* xử lý như không đọc được
    }
    final tOcr = sw.elapsedMilliseconds;
    // Upload ảnh (~1MB) bắt đầu SAU OCR để không giành băng thông.
    final upload = db.storage
        .from('plates')
        .uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    final card = await cardF, open = await openF, extra = await extraF;

    final Decision d;
    if (g == 'in') {
      d = decideEntry(card: card, hasOpenSession: open != null, free: extra['free'] as int, plate: plate);
      if (d.ok) await db.from('sessions').insert({'card_uid': uid, 'plate_in': plate, 'img_in': path});
    } else {
      d = decideExit(card: card, session: open, plateOut: plate, now: now, cfg: FeeConfig.fromRow(extra));
      if (d.ok) await _close(open!['id'] as int, plate, path, d.fee!, null);
    }

    await link.send({
      't': 'res',
      'id': ev['id'],
      'ok': d.ok,
      'open': d.open,
      'l1': plate ?? (d.ok ? 'OK' : 'TU CHOI'),
      'l2': d.message,
    });
    final tReply = sw.elapsedMilliseconds;
    if (!d.ok && g == 'out') _lastDenied = (uid: uid, plate: plate, path: path, at: now);
    last.value = '${d.ok ? 'OK' : 'TU CHOI'} | the $uid | ${plate ?? '?'} | ${d.message}'
        '\nchup ${tShot}ms · OCR ${tOcr - tShot}ms · tra loi ESP32 sau ${tReply}ms';
    // Đọc được qua `adb logcat -s flutter` để đo tốc độ mà không cần nhìn màn hình.
    debugPrint('[gate $g] chup ${tShot}ms | OCR ${tOcr - tShot}ms | DB+tra loi ${tReply - tOcr}ms | '
        'tong ${tReply}ms | ${plate ?? '-'} | ${d.message}');

    // Sau khi cổng đã có kết quả: lưu ảnh, ghi log, cập nhật số chỗ trống cho OLED.
    try {
      await Future.wait([
        upload,
        _log(g, {
          'kind': 'scan',
          'uid': uid,
          'status': d.ok ? 'ok' : 'denied',
          'plate': plate,
          'img': path,
          'message': d.message,
          'open': d.open,
        }),
        _sendStatus(),
      ]);
    } catch (e) {
      last.value = '${last.value}\nGhi log/anh loi: $e';
    }
  }

  /// Bảo vệ mở tay ở cổng ra. PIN: kiểm tra rồi trả kết quả cho ESP32. Vân tay: ESP32 đã tự mở, chỉ ghi log.
  /// Có lượt bị từ chối gần đây -> đóng lượt gửi đó, ghi tên bảo vệ.
  Future<void> _auth(Rec ev) async {
    final pin = ev['pin'] as String?;
    final finger = ev['finger'] as int?;
    final guardId = await db.rpc('find_guard', params: {'p_pin': pin, 'p_finger': finger}) as int?;
    if (pin != null) {
      await link.send({'t': 'auth', 'ok': guardId != null});
      if (guardId == null) {
        last.value = 'Sai PIN bao ve';
        await _log('out', {'kind': 'override', 'status': 'denied', 'message': 'Sai PIN'});
        return;
      }
    }
    var msg = pin != null ? 'PIN bao ve #$guardId' : 'Van tay #$finger${guardId == null ? ' (chua gan bao ve)' : ''}';
    final ref = _lastDenied;
    _lastDenied = null;
    if (ref != null && DateTime.now().difference(ref.at) < deniedRefWindow) {
      final s = await db.from('sessions').select().eq('card_uid', ref.uid).isFilter('time_out', null).maybeSingle();
      if (s != null) {
        final card = await db.from('cards').select().eq('uid', ref.uid).maybeSingle();
        final cfg = FeeConfig.fromRow(await db.from('settings').select().single());
        final fee = feeFor(s, card, DateTime.now(), cfg);
        await _close(s['id'] as int, ref.plate, ref.path, fee, guardId);
        msg += ' | the ${ref.uid} | Phi: ${fee}d';
      }
    }
    await _log('out', {'kind': 'override', 'status': 'done', 'guard_id': guardId, 'message': msg});
    last.value = 'MO THU CONG | $msg';
  }

  Future<void> _openFromApp(Rec row) async {
    if (row['status'] != 'pending') return;
    try {
      await link.send({'t': 'open'});
      await db.from('gate_events').update({'status': 'done'}).eq('id', row['id']);
      last.value = 'Mo cong theo lenh tu app';
    } catch (e) {
      last.value = 'Lenh mo cong loi: $e'; // giữ pending để thấy trên dashboard
    }
  }

  Future<void> _close(int sessionId, String? plate, String? img, int fee, int? guardId) => db
      .from('sessions')
      .update({
        'plate_out': plate,
        'img_out': img,
        'time_out': DateTime.now().toUtc().toIso8601String(),
        'fee': fee,
        'override_by': guardId,
      })
      .eq('id', sessionId)
      .isFilter('time_out', null);
}

