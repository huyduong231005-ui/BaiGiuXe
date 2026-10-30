import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'esp_link.dart';
import 'logic.dart';
import 'offline.dart';

/// Một lần đọc biển: biển tốt nhất, độ tin cậy, các phương án đọc khác (OCR hay nhầm 1 ký tự),
/// loại phương tiện Plate Recognizer nhận ra (Motorcycle, Sedan, SUV... null = không rõ).
typedef PlateRead = ({String plate, double score, List<String> candidates, String? vehicle});

/// Cạnh dài ảnh gửi OCR. Gửi CẢ khung hình (biển ở đâu, góc nào cũng tìm được), chỉ thu nhỏ cho nhanh.
/// Đo thực tế: 1280px (148KB) đọc đúng, tin cậy 0,997, ~1,7s; ảnh gốc 1080x1920 (~1MB) ~2,5s.
const ocrMaxSide = 1280;

/// Gửi ảnh qua REST API (máy chủ giữ token Plate Recognizer, gọi tiếp với regions=vn, strict).
/// Ảnh có nhiều xe -> API lấy biển có độ tin cậy cao nhất. null = không thấy biển.
/// Chờ tối đa 5s (mỗi ảnh ~1,4s): ESP32 chỉ đợi kết quả 12s cho cả chụp, đọc biển, chụp lại và gọi API;
/// API đang ngủ thì lượt này lỗi, CameraScreen ping để giữ API thức.
Future<PlateRead?> recognize(Uint8List jpg) async {
  final r = await api.postJpeg('/plates/recognize', jpg, timeout: const Duration(seconds: 5)) as Rec;
  final plate = r['plate'] as String?;
  if (plate == null || plate.isEmpty) return null;
  return (
    plate: plate,
    score: (r['score'] as num).toDouble(),
    candidates: (r['candidates'] as List).cast<String>(),
    vehicle: r['vehicle'] as String?,
  );
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

/// Vai trò camera của một cổng: nhận sự kiện từ ESP32 qua MQTT, chụp + đọc biển rồi gọi API. API kiểm tra
/// thẻ / biển / chỗ trống, ghi lượt gửi + nhật ký và trả sẵn 2 dòng chữ cho OLED; ĐT chuyển lại cho ESP32.
class GateStation {
  GateStation(this.gate, this.camera, this.link);

  /// Bảo vệ mở tay chỉ đóng lượt gửi của lần bị từ chối gần đây (tránh đóng nhầm xe khác).
  static const deniedRefWindow = Duration(seconds: 60);

  /// ESP32 chờ kết quả tối đa 12 giây kể từ lúc quẹt thẻ.
  static const espWait = Duration(seconds: 11);

  /// ĐT cổng ra hỏi API lệnh "Mở cổng ra" từ app quản lý theo nhịp này.
  static const commandPoll = Duration(seconds: 3);

  /// Làm mới danh sách thẻ tháng (dùng khi mất mạng) và gửi bù hàng chờ offline.
  static const whitelistEvery = Duration(minutes: 5);
  static const flushEvery = Duration(seconds: 30);

  final String gate; // 'in' | 'out' | 'both' (1 điện thoại cho cả 2 cổng)
  final CameraController camera;
  final EspLink link;
  ValueNotifier<String> get status => link.status;
  final last = ValueNotifier<String>('Chua co xe');
  final busy = ValueNotifier<bool>(false); // true trong lúc xử lý một lượt quẹt thẻ
  final history = ValueNotifier<List<ScanResult>>(const []); // mới nhất trước, để bảo vệ xem lại khi xe xếp hàng

  /// Chỉ đường cho xe vừa vào: mặt bằng (không biển số) + đường từ cổng tới ô API vừa chỉ. Tự ẩn sau [guideFor].
  final guide = ValueNotifier<({Rec map, Rec route})?>(null);
  static const guideFor = Duration(seconds: 40);
  Timer? _guideTimer;

  void _addHistory(String g, String? plate, bool ok, String msg) =>
      history.value = [(at: DateTime.now(), gate: g, plate: plate, ok: ok, msg: msg), ...history.value.take(19)];

  StreamSubscription<Rec>? _sub;
  Timer? _commands, _wlTimer, _flushTimer;
  GateOffline? _offline;
  bool get _guardsEsp => gate != 'in'; // ĐT cổng ra (hoặc cả 2) lo phần bảo vệ, danh sách thẻ, gửi bù của ESP32
  bool _polling = false;
  Future<void> _queue = Future.value(); // camera chỉ chụp được tuần tự
  ({String uid, String? plate, String path, DateTime at})? _lastDenied;

  void start() {
    link.onConnected = _syncEsp;
    // Mọi điện thoại đều nhận mọi bản tin; mỗi cổng chỉ xử lý bản tin có g == cổng của mình.
    _sub = link.events
        .where((ev) => gate == 'both' || ev['g'] == gate)
        // Ghi lúc nhận: ESP32 bắt đầu đếm giờ chờ từ lúc quẹt, kể cả khi lượt này còn xếp hàng sau lượt trước.
        .listen((ev) {
      final at = DateTime.now();
      _queue = _queue.then((_) => _handle({...ev, '_at': at}));
    });
    // Nút "Mở cổng ra" trên app Quản lý -> API -> ĐT cổng ra hỏi định kỳ -> MQTT -> ESP32.
    if (gate != 'in') _commands = Timer.periodic(commandPoll, (_) => _pollCommands());
    link.start();
    SharedPreferences.getInstance().then((p) {
      _offline = GateOffline(p);
      _refreshWhitelist();
      _wlTimer = Timer.periodic(whitelistEvery, (_) => _refreshWhitelist());
      _flushTimer = Timer.periodic(flushEvery, (_) => _flush());
    });
  }

  Future<void> _refreshWhitelist() async {
    try {
      if (await _offline!.refreshWhitelist() && _guardsEsp && link.connected) await _sendWhitelist();
    } catch (e) {
      debugPrint('[offline] lay danh sach the thang loi: $e'); // mất mạng: giữ danh sách cũ
    }
  }

  /// Gửi danh sách thẻ tháng cho ESP32 lưu vào flash (ESP32 tự cho cư dân qua khi mất ĐT / mất mạng).
  Future<void> _sendWhitelist() async {
    final msgs = whitelistMessages(_offline?.whitelist ?? const []);
    for (final m in msgs) {
      await link.send(m);
      await Future.delayed(const Duration(milliseconds: 80)); // ESP32 xử lý tuần tự, tránh dồn bộ đệm MQTT
    }
    debugPrint('[offline] da gui ${_offline?.whitelist.length} the thang cho ESP32 (${msgs.length} ban tin)');
  }

  Future<void> _flush() async {
    try {
      final n = await _offline?.flush() ?? 0;
      if (n > 0) last.value = 'Da gui bu $n luot ra vao luc mat mang';
    } catch (_) {} // vẫn mất mạng: thử lại nhịp sau
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _commands?.cancel();
    _wlTimer?.cancel();
    _flushTimer?.cancel();
    _guideTimer?.cancel();
    await link.stop();
  }

  /// Vừa kết nối: chỉnh giờ DS3231 theo điện thoại + gửi số chỗ trống.
  Future<void> _syncEsp() async {
    try {
      final now = DateTime.now();
      await link.send({'t': 'time', 'ts': now.millisecondsSinceEpoch ~/ 1000 + now.timeZoneOffset.inSeconds});
      if (_guardsEsp) await _sendWhitelist();
      await _sendStatus(await api.get('/status') as Rec);
    } catch (e) {
      last.value = 'Dong bo ESP32 loi: $e';
    }
  }

  Future<void> _sendStatus(Rec st) => _esp({'t': 'st', 'free': st['free'], 'cap': st['capacity']});

  /// Gửi cho ESP32 nếu đang kết nối (quẹt thử không có ESP32 thì bỏ qua).
  Future<void> _esp(Rec msg) async {
    if (link.connected) await link.send(msg);
  }

  /// Quẹt thử: chạy đúng quy trình một lượt quẹt thẻ (chụp, đọc biển, API quyết định, chỉ ô) mà không cần ESP32 /
  /// đầu đọc RFID. Dùng để kiểm tra camera + nhận diện biển, hoặc demo khi phần cứng lỗi.
  void simulateScan(String uid, String g) =>
      _queue = _queue.then((_) => _scanGuarded({'t': 'scan', 'g': g, 'uid': uid, 'id': 0}));

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
          await api.post('/gate/emergency', {'on': ev['on'] == true});
        case 'off':
          await _forwardOffline(ev);
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
      if (ev['id'] != 0) {
        await _esp({'t': 'res', 'id': ev['id'], 'ok': false, 'open': false, 'l1': 'TU CHOI', 'l2': 'Loi he thong'});
      }
    } finally {
      busy.value = false;
    }
  }

  Future<void> _scan(Rec ev) async {
    final uid = ev['uid'] as String;
    final g = ev['g'] as String; // cổng của lượt quẹt (vai trò 'both' xử lý cả 2 cổng)
    final fromEsp = ev['id'] != 0; // id 0 = quẹt thử trên app: không có ESP32 đang chờ
    final sw = Stopwatch()..start();
    // Giờ ESP32 còn chờ, tính từ lúc nhận sự kiện (gồm cả lúc xếp hàng sau lượt trước).
    final queued = DateTime.now().difference(ev['_at'] as DateTime? ?? DateTime.now());
    Duration left() => espWait - queued - sw.elapsed;

    var bytes = await shoot(camera);
    final tShot = sw.elapsedMilliseconds;
    final now = DateTime.now();
    final path = '$g/${now.toIso8601String().substring(0, 10)}/${now.millisecondsSinceEpoch}_$uid.jpg';

    var read = await _tryRead(bytes);
    var shots = 1;
    // Chụp lại chỉ khi còn đủ giờ cho 1 lần chụp + đọc (~6s) và gọi API.
    if ((read == null || read.score < minPlateScore) && (!fromEsp || left() > const Duration(seconds: 8))) {
      // Không thấy biển / đọc chưa chắc (xe đang lăn, bị che...): chụp lại 1 lần, giữ kết quả tốt hơn.
      // ponytail: mỗi lần chụp lại tốn thêm 1 lượt OCR (gói free 2.500 lượt/tháng).
      final bytes2 = await shoot(camera);
      shots = 2;
      final read2 = await _tryRead(bytes2);
      if (read2 != null && (read == null || read2.score > read.score)) {
        bytes = bytes2;
        read = read2;
      }
    }
    final plate = read?.plate;
    final tOcr = sw.elapsedMilliseconds;

    // API quyết định (thẻ, chỗ trống, biển, ô đậu cho khách) + ghi lượt gửi, nhật ký, số đo nhận diện;
    // phần thời gian còn lại trước khi ESP32 thôi chờ. API không gọi được -> chế độ offline.
    // ESP32 đã thôi chờ (tự xử lý offline, gửi bù sau) thì không ghi lượt nữa: tránh API đóng / mở lượt gửi trong
    // khi barrier không làm theo.
    if (fromEsp && left() <= Duration.zero) {
      _addHistory(g, plate, false, 'Qua gio, ESP32 tu xu ly');
      last.value = 'Bo luot the $uid: ESP32 da thoi cho (${sw.elapsedMilliseconds + queued.inMilliseconds}ms)';
      return;
    }
    Rec r;
    try {
      r = await api.postWithin('/gate/scan', {
        'gate': g,
        'uid': uid,
        'plate': plate,
        'score': read?.score ?? 0,
        'candidates': read?.candidates ?? const <String>[],
        'vehicle': read?.vehicle,
        'img': path,
        'shots': shots,
        'ocrMs': tOcr - tShot,
        'totalMs': sw.elapsedMilliseconds, // tới lúc gửi API; phần còn lại là API + MQTT (~0,3s)
      }, fromEsp ? left() : const Duration(seconds: 15)) as Rec;
    } on ApiException catch (e) {
      if (e.status != null) rethrow; // API trả lỗi nghiệp vụ / lỗi máy chủ: không phải mất mạng
      r = await _offlineDecision(g, uid, plate, now);
    }
    final ok = r['ok'] == true;
    final message = r['l2'] as String;
    if (fromEsp) await _esp({'t': 'res', 'id': ev['id'], 'ok': ok, 'open': r['open'] == true, 'l1': r['l1'], 'l2': message});
    final tReply = sw.elapsedMilliseconds;
    if (!ok && g == 'out') _lastDenied = (uid: uid, plate: plate, path: path, at: now);
    _addHistory(g, plate, ok, message);
    if (ok && r['route'] != null) unawaited(_showGuide(r['route'] as Rec));
    last.value = '${ok ? 'OK' : 'TU CHOI'} | the $uid | ${plate ?? '?'} | $message'
        '\nchup ${tShot}ms · OCR ${tOcr - tShot}ms · tra loi ESP32 sau ${tReply}ms';
    // Đọc được qua `adb logcat -s flutter` để đo tốc độ mà không cần nhìn màn hình.
    debugPrint('[gate $g] chup ${tShot}ms | OCR ${tOcr - tShot}ms | API+tra loi ${tReply - tOcr}ms | '
        'tong ${tReply}ms | ${plate ?? '-'} | $message');

    // Sau khi cổng đã có kết quả: số chỗ trống cho OLED, tải ảnh (đã thu nhỏ) lên API.
    try {
      if (r['status'] == null) return; // offline: không có số chỗ, ảnh không gửi được
      await _sendStatus(r['status'] as Rec);
    } catch (e) {
      last.value = '${last.value}\nGui so cho loi: $e';
    }
    // Tải ảnh không chặn hàng chờ: lượt quẹt kế tiếp không phải đợi ảnh lượt này lên xong.
    if (r['status'] != null) {
      unawaited(compute(shrinkForOcr, bytes)
          .then((small) => api.putJpeg('/gate/images', small, {'path': path}))
          .catchError((Object e) => last.value = '${last.value}\nGui anh loi: $e'));
    }
  }

  /// Bảo vệ mở tay ở cổng ra. PIN: API kiểm tra rồi trả kết quả cho ESP32. Vân tay: ESP32 đã tự mở, chỉ ghi log.
  /// Có lượt bị từ chối gần đây -> API đóng lượt gửi đó, ghi tên bảo vệ.
  Future<void> _auth(Rec ev) async {
    final pin = ev['pin'] as String?;
    final enroll = ev['for'] == 'enroll'; // phím B: PIN đúng thì ESP32 đăng ký vân tay vào ô = ID bảo vệ
    final ref = _lastDenied;
    final recent = ref != null && DateTime.now().difference(ref.at) < deniedRefWindow;
    final r = await api.post('/gate/auth', {
      'pin': pin,
      'finger': ev['finger'],
      'enroll': enroll,
      'denied': recent ? {'uid': ref.uid, 'plate': ref.plate, 'img': ref.path} : null,
    }) as Rec;
    if (pin != null) await link.send({'t': 'auth', 'ok': r['ok'], 'gid': r['guardId']});
    if (r['ok'] == true && !enroll) _lastDenied = null;
    last.value = r['ok'] == true ? (enroll ? '${r['message']} tai ESP32...' : 'MO THU CONG | ${r['message']}') : '${r['message']}';
  }

  /// ESP32 vừa lưu vân tay vào ô id (= ID bảo vệ).
  Future<void> _enrolled(int id) async {
    final r = await api.post('/gate/enrolled', {'id': id}) as Rec;
    last.value = r['message'] as String;
  }

  /// Chấm công (phím C): API quyết định vào / ra ca và trả 2 dòng chữ cho OLED.
  Future<void> _attendance(Rec ev) async {
    final r = await api.post('/gate/punch', {'pin': ev['pin'], 'finger': ev['finger']}) as Rec;
    if (r['ok'] != true && r['pinWrong'] == true) {
      await link.send({'t': 'auth', 'ok': false}); // ESP32 đếm sai PIN như lúc mở cổng
    } else {
      await link.send({'t': 'attres', 'ok': r['ok'] == true, 'l1': r['l1'], 'l2': r['l2']});
    }
    last.value = r['ok'] == true ? 'CHAM CONG | ${r['message']}' : 'Cham cong: khong nhan ra bao ve';
  }

  Future<void> _pollCommands() async {
    if (_polling) return;
    _polling = true;
    try {
      for (final c in (await api.get('/gate/commands') as List).cast<Rec>()) {
        await link.send({'t': 'open'});
        await api.post('/gate/commands/${c['id']}/done');
        last.value = 'Mo cong theo lenh tu app';
      }
    } catch (e) {
      debugPrint('[gate] hoi lenh mo cong loi: $e'); // mất mạng: thử lại nhịp sau
    } finally {
      _polling = false;
    }
  }

  Future<void> _showGuide(Rec route) async {
    try {
      guide.value = (map: await api.get('/lot/map/public') as Rec, route: route);
      _guideTimer?.cancel();
      _guideTimer = Timer(guideFor, () => guide.value = null);
    } catch (_) {} // không lấy được mặt bằng thì chỉ hiện mã ô như cũ
  }

  /// Mất mạng tới API: thẻ tháng còn hạn (danh sách đã lưu) thì cho qua và xếp hàng chờ gửi bù; thẻ khác từ chối.
  Future<Rec> _offlineDecision(String g, String uid, String? plate, DateTime now) async {
    final ok = _offline?.allows(uid, now) ?? false;
    if (ok) await _offline!.add(g, uid, now);
    return {
      'ok': ok,
      'open': ok && g != 'in',
      'l1': plate ?? (ok ? 'CU DAN' : 'TU CHOI'),
      'l2': ok ? 'Mat mang - moi qua' : 'Mat mang, goi bao ve',
      'status': null,
    };
  }

  /// ESP32 gửi bù các lượt ghi lúc mất ĐT / mất mạng: chuyển lên API rồi báo ESP32 xoá phần đã gửi.
  Future<void> _forwardOffline(Rec ev) async {
    final events = (ev['ev'] as List).cast<Rec>();
    final r = await api.post('/gate/offline', {'events': events}) as Rec;
    await link.send({'t': 'offack', 'n': events.length});
    last.value = 'ESP32 gui bu ${events.length} luot (ghi moi ${r['applied']})';
  }

  /// Lỗi mạng / OCR -> null (API xử lý như không đọc được biển) và hiện lỗi trên màn camera.
  Future<PlateRead?> _tryRead(Uint8List jpg) async {
    try {
      return await readPlate(jpg);
    } catch (e) {
      last.value = 'OCR loi: $e';
      return null;
    }
  }
}
