import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'esp_link.dart';
import 'logic.dart';

const plateToken = String.fromEnvironment('PLATE_TOKEN');

/// Một lần đọc biển: biển tốt nhất, độ tin cậy, và các phương án đọc khác (OCR hay nhầm 1 ký tự).
typedef PlateRead = ({String plate, double score, List<String> candidates});

/// Cạnh dài ảnh gửi OCR. Gửi CẢ khung hình (biển ở đâu, góc nào cũng tìm được), chỉ thu nhỏ cho nhanh.
/// Đo thực tế: 1280px (148KB) đọc đúng, tin cậy 0,997, ~1,7s; ảnh gốc 1080x1920 (~1MB) ~2,5s.
const ocrMaxSide = 1280;

/// Gửi ảnh lên Plate Recognizer. Ảnh có nhiều xe -> lấy biển có độ tin cậy cao nhất. null = không thấy biển.
Future<PlateRead?> recognize(Uint8List jpg) async {
  // ponytail: token nằm trong file build; chuyển sang Edge Function proxy nếu phát hành app ra ngoài.
  final req = http.MultipartRequest('POST', Uri.parse('https://api.platerecognizer.com/v1/plate-reader/'))
    ..headers['Authorization'] = 'Token $plateToken'
    ..fields['regions'] = 'vn'
    ..fields['config'] = '{"region":"strict"}' // chỉ nhận kết quả đúng mẫu biển Việt Nam
    ..files.add(http.MultipartFile.fromBytes('upload', jpg, filename: 'shot.jpg'));
  final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 8)));
  if (res.statusCode != 200 && res.statusCode != 201) {
    throw Exception('PlateRecognizer ${res.statusCode}: ${res.body}');
  }
  final results = (jsonDecode(res.body)['results'] as List).cast<Rec>();
  if (results.isEmpty) return null;
  final best = results.reduce((a, b) => (a['score'] as num) >= (b['score'] as num) ? a : b);
  final plate = normPlate(best['plate'] as String);
  final cands = [for (final c in (best['candidates'] as List? ?? const [])) normPlate((c as Rec)['plate'] as String)];
  return (plate: plate, score: (best['score'] as num).toDouble(), candidates: cands.isEmpty ? [plate] : cands);
}

Uint8List shrinkForOcr(Uint8List jpg) {
  final im = img.bakeOrientation(img.decodeJpg(jpg)!);
  final side = im.width > im.height ? im.width : im.height;
  final out = side <= ocrMaxSide
      ? im
      : img.copyResize(im, width: im.width * ocrMaxSide ~/ side, height: im.height * ocrMaxSide ~/ side,
          interpolation: img.Interpolation.average);
  return img.encodeJpg(out, quality: 85);
}

Future<PlateRead?> readPlate(Uint8List jpg) async {
  Uint8List small;
  try {
    small = await compute(shrinkForOcr, jpg); // isolate riêng: giải mã JPEG không làm giật giao diện
  } catch (e) {
    debugPrint('[ocr] thu nho anh loi, gui anh goc: $e');
    small = jpg;
  }
  return recognize(small);
}

/// Gọi một lần khi mở camera: tắt flash để khỏi chờ đèn đo sáng trước mỗi lần chụp.
/// Lấy nét + đo sáng để camera tự động trên toàn khung (biển có thể ở bất kỳ đâu trong ảnh).
Future<void> setupGateCamera(CameraController camera) async {
  try {
    await camera.setFlashMode(FlashMode.off);
  } on CameraException catch (e) {
    debugPrint('[camera] khong tat duoc flash: $e'); // vẫn chụp được
  }
}

Future<Uint8List> shoot(CameraController camera) async => (await camera.takePicture()).readAsBytes();

typedef ScanResult = ({DateTime at, String gate, String? plate, bool ok, String msg});

/// Vai trò camera của một cổng: nhận sự kiện từ ESP32 qua MQTT, chụp + đọc biển, quyết định,
/// trả kết quả cho ESP32 qua MQTT rồi mới ghi Supabase (không nằm trên đường chờ của cổng).
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
  final history = ValueNotifier<List<ScanResult>>(const []); // mới nhất trước, để bảo vệ xem lại khi xe xếp hàng

  void _addHistory(String g, String? plate, bool ok, String msg) =>
      history.value = [(at: DateTime.now(), gate: g, plate: plate, ok: ok, msg: msg), ...history.value.take(19)];

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
      // Nút "Mở cổng ra" trên app Quản lý -> gate_events(open_cmd) -> ĐT cổng ra -> MQTT -> ESP32.
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
        case 'enrolled':
          await _enrolled(ev['id'] as int);
        case 'att':
          await _attendance(ev);
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
      _addHistory(ev['g'] as String, null, false, 'Loi he thong');
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
    // Biển các xe đang trong bãi: chặn một biển vào 2 lần bằng 2 thẻ khác nhau.
    final parkedF = g == 'in'
        ? db.from('sessions').select('plate_in').isFilter('time_out', null).then(
            (rows) => [for (final r in rows) if (r['plate_in'] != null) r['plate_in'] as String])
        : Future.value(const <String>[]);

    var bytes = await shoot(camera);
    final tShot = sw.elapsedMilliseconds;
    final now = DateTime.now();
    final path = '$g/${now.toIso8601String().substring(0, 10)}/${now.millisecondsSinceEpoch}_$uid.jpg';

    var read = await _tryRead(bytes);
    if (read == null || read.score < minPlateScore) {
      // Không thấy biển / đọc chưa chắc (xe đang lăn, bị che...): chụp lại 1 lần, giữ kết quả tốt hơn.
      // ponytail: mỗi lần chụp lại tốn thêm 1 lượt OCR (gói free 2.500 lượt/tháng).
      final bytes2 = await shoot(camera);
      final read2 = await _tryRead(bytes2);
      if (read2 != null && (read == null || read2.score > read.score)) {
        bytes = bytes2;
        read = read2;
      }
    }
    final plate = read?.plate;
    final tOcr = sw.elapsedMilliseconds;
    // Upload ảnh (~1MB) bắt đầu SAU OCR để không giành băng thông.
    final upload = db.storage
        .from('plates')
        .uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    final card = await cardF, open = await openF, extra = await extraF, parked = await parkedF;

    final Decision d;
    if (g == 'in') {
      d = decideEntry(
          card: card, hasOpenSession: open != null, free: extra['free'] as int, plate: plate,
          score: read?.score ?? 0, candidates: read?.candidates ?? const [], parkedPlates: parked);
      if (d.ok) await db.from('sessions').insert({'card_uid': uid, 'plate_in': plate, 'img_in': path});
    } else {
      d = decideExit(
          card: card, session: open, plateOut: plate, candidates: read?.candidates ?? const [],
          now: now, cfg: FeeConfig.fromRow(extra));
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
    _addHistory(g, plate, d.ok, d.message);
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
    final forEnroll = ev['for'] == 'enroll'; // phím B: PIN đúng thì ESP32 đăng ký vân tay vào ô = ID bảo vệ
    final guardId = await db.rpc('find_guard', params: {'p_pin': pin, 'p_finger': finger}) as int?;
    if (pin != null) {
      await link.send({'t': 'auth', 'ok': guardId != null, 'gid': guardId});
      if (guardId == null) {
        last.value = 'Sai PIN bao ve';
        await _log('out', {'kind': 'override', 'status': 'denied', 'message': forEnroll ? 'Sai PIN (dang ky van tay)' : 'Sai PIN'});
        return;
      }
      if (forEnroll) {
        last.value = 'Bao ve #$guardId dang dang ky van tay tai ESP32...';
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

  /// ESP32 vừa lưu vân tay vào ô id (= ID bảo vệ): gán cho bảo vệ đó, gỡ khỏi bảo vệ khác đang giữ số này
  /// (finger_id là unique).
  Future<void> _enrolled(int id) async {
    await db.from('guards').update({'finger_id': null}).eq('finger_id', id).neq('id', id);
    await db.from('guards').update({'finger_id': id}).eq('id', id);
    await _log('out', {'kind': 'override', 'status': 'done', 'guard_id': id, 'message': 'Dang ky van tay #$id'});
    last.value = 'Da dang ky van tay cho bao ve #$id';
  }

  /// Chấm công (phím C): bảo vệ chưa trong ca -> vào ca gần nhất theo lịch; đang trong ca -> ra ca.
  /// Ca mở quá [maxShiftLength] coi như quên chấm ra: đóng ở giờ hết ca rồi mở ca mới.
  Future<void> _attendance(Rec ev) async {
    final pin = ev['pin'] as String?;
    final finger = ev['finger'] as int?;
    final gid = await db.rpc('find_guard', params: {'p_pin': pin, 'p_finger': finger}) as int?;
    if (gid == null) {
      if (pin != null) {
        await link.send({'t': 'auth', 'ok': false}); // ESP32 đếm sai PIN như lúc mở cổng
        await _log('out', {'kind': 'override', 'status': 'denied', 'message': 'Sai PIN (cham cong)'});
      } else {
        await link.send({'t': 'attres', 'ok': false, 'l1': 'KHONG RO', 'l2': 'Van tay #$finger chua gan'});
      }
      last.value = 'Cham cong: khong nhan ra bao ve';
      return;
    }
    final now = DateTime.now();
    final method = pin != null ? 'pin' : 'finger';
    final guard = await db.from('guards').select('name').eq('id', gid).single();
    final name = oledName(guard['name'] as String);
    final open = await db.from('attendance').select().eq('guard_id', gid).isFilter('time_out', null).maybeSingle();
    final String l1, l2, logMsg;
    if (open != null && now.difference(DateTime.parse(open['time_in'] as String)) < maxShiftLength) {
      await db.from('attendance').update({'time_out': now.toUtc().toIso8601String(), 'method_out': method}).eq('id', open['id']);
      final end = open['shift_end'] == null ? null : DateTime.parse(open['shift_end'] as String).toLocal();
      final early = end == null ? 0 : end.difference(now).inMinutes;
      l1 = 'RA CA';
      l2 = '$name ${hm(now)}${early > 0 ? ' som ${early}p' : ''}';
      logMsg = 'Ra ca: ${open['shift_name'] ?? '-'}${early > 0 ? ' (ve som ${early}p)' : ''}';
    } else {
      if (open != null) {
        await db
            .from('attendance')
            .update({'time_out': open['shift_end'] ?? open['time_in'], 'method_out': 'auto'}).eq('id', open['id']);
      }
      final defs = [for (final r in await db.from('shift_defs').select()) shiftDefFromRow(r)];
      final s = nearestShift(defs, now);
      await db.from('attendance').insert({
        'guard_id': gid,
        'shift_id': s?.def.id,
        'shift_name': s?.def.name,
        'shift_start': s?.start.toUtc().toIso8601String(),
        'shift_end': s?.end.toUtc().toIso8601String(),
        'method_in': method,
      });
      final late = s == null ? 0 : now.difference(s.start).inMinutes;
      l1 = 'VAO CA';
      l2 = '$name ${hm(now)}${late > 0 ? ' tre ${late}p' : ''}';
      logMsg = 'Vao ca: ${s?.def.name ?? '-'}${late > 0 ? ' (tre ${late}p)' : ''}';
    }
    await link.send({'t': 'attres', 'ok': true, 'l1': l1, 'l2': l2});
    await _log('out', {'kind': 'override', 'status': 'done', 'guard_id': gid, 'message': logMsg});
    last.value = 'CHAM CONG | ${guard['name']} | $logMsg';
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

  /// Lỗi mạng / OCR -> null (decide* xử lý như không đọc được biển) và hiện lỗi trên màn camera.
  Future<PlateRead?> _tryRead(Uint8List jpg) async {
    try {
      return await readPlate(jpg);
    } catch (e) {
      last.value = 'OCR loi: $e';
      return null;
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

