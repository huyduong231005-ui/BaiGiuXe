import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api.dart';
import '../esp_link.dart';
import '../gate_station.dart';
import '../logic.dart';
import '../main.dart' show ManagerHome, prefs;

/// Render free ngủ sau 15 phút không có request; ping định kỳ để lượt quẹt thẻ không phải chờ API thức dậy.
const _keepApiAwake = Duration(minutes: 10);

/// Điện thoại gắn ở cổng, kiêm luôn màn quản lý.
/// Màn camera ở lại liên tục để quét xe xếp hàng: mỗi lượt quẹt, GateStation tự chụp + nhận diện,
/// kết quả mới nhất hiện to, vài xe trước xếp bên dưới. Đang ở màn Quản lý mà có lượt quẹt -> tự về camera.
/// Camera luôn bật ngầm khi đang ở màn Quản lý để lượt quẹt sau không phải chờ khởi động camera.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.gate, required this.onExit, this.nested = false});

  final String gate;
  final VoidCallback onExit;

  /// true: mở từ tab Khác của màn quản lý (đã có thanh tab bên dưới). Nút "Quản lý" đóng camera để quay về,
  /// không dựng thêm một bộ tab quản lý chồng lên.
  final bool nested;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  static const historyShown = 2; // ít dòng: không che khung hình camera

  CameraController? cam;
  GateStation? station;
  String? error;
  double zoom = 1, maxZoom = 1;
  bool showCamera = true;
  Timer? _ping;

  String get _zoomKey => 'zoom_${widget.gate}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    _wakeApi();
    _ping = Timer.periodic(_keepApiAwake, (_) => _wakeApi());
  }

  void _wakeApi() => api.get('/health').catchError((_) => null); // lỗi mạng: thử lại nhịp sau

  // Theo hướng dẫn của plugin camera: nhả camera khi app bị ẩn, mở lại khi quay về.
  // Nếu không, camera vẫn đẩy khung hình sau khi engine tách ra -> app crash lúc thoát.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Chỉ nhả camera + ngắt trạm cổng khi app thật sự xuống nền (paused). "inactive" xảy ra cả khi kéo thanh
    // thông báo / mở trình chuyển app: ngắt lúc đó làm ESP32 tưởng mất ĐT và tự xử lý offline.
    if ((state == AppLifecycleState.paused || state == AppLifecycleState.hidden) && cam != null) {
      _release();
      setState(() => cam = null);
    } else if (state == AppLifecycleState.resumed && cam == null && error == null) {
      _init();
    }
  }

  void _release() {
    station?.busy.removeListener(_onBusy);
    station?.stop();
    station = null;
    // CameraX đôi khi báo lỗi khi nhả surface lúc đóng: bỏ qua, camera vẫn được giải phóng.
    cam?.dispose().catchError((Object e) => debugPrint('[camera] dong camera loi: $e'));
    WakelockPlus.disable();
  }

  Future<void> _init() async {
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      // 1080p: biển số chiếm nhiều điểm ảnh hơn -> nhận diện tốt hơn 720p.
      final c = CameraController(back, ResolutionPreset.veryHigh, enableAudio: false);
      await c.initialize();
      maxZoom = (await c.getMaxZoomLevel()).clamp(1, 8).toDouble();
      zoom = (prefs.getDouble(_zoomKey) ?? 1).clamp(1, maxZoom).toDouble();
      await c.setZoomLevel(zoom);
      await setupGateCamera(c);
      await WakelockPlus.enable();
      station = GateStation(widget.gate, c, EspLink(widget.gate))
        ..busy.addListener(_onBusy)
        ..start();
      if (mounted) setState(() => cam = c);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  /// Bắt đầu lượt quẹt -> hiện camera. Xong lượt vẫn ở lại camera để quét xe tiếp theo.
  void _onBusy() {
    if (station!.busy.value && !showCamera) setState(() => showCamera = true);
  }

  @override
  void dispose() {
    _ping?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _release();
    super.dispose();
  }

  Future<void> _setZoom(double z) async {
    setState(() => zoom = z);
    await cam!.setZoomLevel(z);
    await prefs.setDouble(_zoomKey, z);
  }

  @override
  Widget build(BuildContext context) => widget.nested
      ? _cameraView()
      : IndexedStack(
          index: showCamera ? 0 : 1,
          children: [
            _cameraView(),
            ManagerHome(onChangeRole: widget.onExit, onShowCamera: () => setState(() => showCamera = true)),
          ],
        );

  /// Chọn thẻ (và cổng nếu máy lo cả 2 cổng) rồi chạy một lượt quẹt thẻ giả: camera chụp + đọc biển thật.
  Future<void> _simulate() async {
    final List<Rec> cards;
    try {
      cards = ((await api.get('/cards')) as List).cast<Rec>();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted) return;
    var gate = widget.gate == 'both' ? 'in' : widget.gate;
    final uid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
            child: ListView(shrinkWrap: true, children: [
              const ListTile(title: Text('Quẹt thử', style: TextStyle(fontWeight: FontWeight.w600))),
              if (widget.gate == 'both')
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'in', label: Text('Cổng vào'), icon: Icon(Icons.login)),
                      ButtonSegment(value: 'out', label: Text('Cổng ra'), icon: Icon(Icons.logout)),
                    ],
                    selected: {gate},
                    onSelectionChanged: (v) => setS(() => gate = v.first),
                  ),
                ),
              for (final card in cards)
                ListTile(
                  leading: Icon(card['kind'] == 'monthly' ? Icons.event_repeat : Icons.credit_card),
                  title: Text('${card['uid']}${card['plate'] == null ? '' : ' · ${card['plate']}'}'),
                  subtitle: Text(card['kind'] == 'monthly' ? 'Vé tháng${card['slot_code'] == null ? '' : ' · ô ${card['slot_code']}'}' : 'Vé lượt (khách vãng lai)'),
                  onTap: () => Navigator.pop(c, card['uid'] as String),
                ),
            ]),
          ),
        ),
      ),
    );
    if (uid != null) station?.simulateScan(uid, gate);
  }

  Widget _cameraView() {
    final title = switch (widget.gate) {
      'in' => 'Camera cổng vào',
      'out' => 'Camera cổng ra',
      _ => 'Camera cả 2 cổng',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(onPressed: _simulate, icon: const Icon(Icons.touch_app_outlined), tooltip: 'Quẹt thử (không cần ESP32)'),
          TextButton.icon(
            onPressed: widget.nested ? widget.onExit : () => setState(() => showCamera = false),
            icon: const Icon(Icons.dashboard),
            label: const Text('Quản lý'),
          ),
        ],
      ),
      body: error != null
          ? Center(child: Text('Lỗi camera: $error'))
          : cam == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              fit: StackFit.expand,
              children: [
                Center(child: CameraPreview(cam!)),
                Align(
                  alignment: Alignment.topCenter,
                  child: ValueListenableBuilder(
                    valueListenable: station!.status,
                    builder: (_, v, _) => Container(
                      width: double.infinity,
                      color: v == 'Da ket noi ESP32' ? Colors.green.shade700 : Colors.orange.shade800,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(v == 'Da ket noi ESP32' ? Icons.wifi : Icons.wifi_off, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(v, style: const TextStyle(color: Colors.white, fontSize: 16)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Chỉ dẫn gọn cho xe vừa vào (ô + 1 dòng), tự ẩn sau 3s / chạm để ẩn: không che camera cho xe kế tiếp.
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 44),
                    child: ValueListenableBuilder(
                      valueListenable: station!.guide,
                      builder: (_, g, _) => g == null
                          ? const SizedBox.shrink()
                          : GestureDetector(
                              onTap: station!.hideGuide,
                              child: Card(
                                margin: const EdgeInsets.symmetric(horizontal: 8),
                                color: Colors.black.withValues(alpha: 0.75),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                                    Text('Mời vào ô ${g['slot']}',
                                        style: const TextStyle(color: Colors.yellowAccent, fontSize: 24, fontWeight: FontWeight.bold)),
                                    Text(g['hint'] as String, textAlign: TextAlign.center, maxLines: 2,
                                        style: const TextStyle(color: Colors.white, fontSize: 14)),
                                  ]),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                    top: false, // không để thanh điều hướng Android che dòng cuối
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder(
                          valueListenable: station!.busy,
                          builder: (_, busy, _) => busy
                              ? Container(
                                  width: double.infinity,
                                  color: Colors.amber.shade800,
                                  padding: const EdgeInsets.all(8),
                                  child: const Row(
                                    children: [
                                      SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      ),
                                      SizedBox(width: 12),
                                      Text(
                                        'Đang chụp + đọc biển số...',
                                        style: TextStyle(color: Colors.white, fontSize: 16),
                                      ),
                                    ],
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        _History(station!.history, showGate: widget.gate == 'both', max: historyShown),
                        if (maxZoom > 1)
                          Container(
                            color: Colors.black54,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                const Icon(Icons.zoom_in, color: Colors.white),
                                Expanded(
                                  child: Slider(
                                    value: zoom,
                                    min: 1,
                                    max: maxZoom,
                                    divisions: ((maxZoom - 1) * 10).round().clamp(1, 70),
                                    onChanged: _setZoom,
                                  ),
                                ),
                                Text('${zoom.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                        _Banner(station!.last, fontSize: 13), // chi tiết thời gian + lỗi
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {this.fontSize = 18});

  final ValueNotifier<String> text;
  final double fontSize;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: text,
    builder: (_, v, _) => v.isEmpty ? const SizedBox.shrink() : Container(
      width: double.infinity,
      color: Colors.black54,
      padding: const EdgeInsets.all(12),
      child: Text(
        v,
        style: TextStyle(color: Colors.white, fontSize: fontSize),
      ),
    ),
  );
}

/// Các xe vừa quét, mới nhất ở trên và chữ to: xe xếp hàng thì bảo vệ vẫn xem lại được xe trước.
class _History extends StatelessWidget {
  const _History(this.list, {required this.showGate, required this.max});

  final ValueNotifier<List<ScanResult>> list;
  final bool showGate;
  final int max;

  static String _hms(DateTime t) => [t.hour, t.minute, t.second].map((v) => '$v'.padLeft(2, '0')).join(':');

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: list,
    builder: (_, items, _) => Column(
      children: [
        for (final (i, r) in items.take(max).indexed)
          Container(
            width: double.infinity,
            color: i == 0 ? (r.ok ? Colors.green.shade800 : Colors.red.shade800) : Colors.black54,
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: i == 0 ? 10 : 4),
            child: Row(
              children: [
                Icon(
                  r.ok ? Icons.check_circle : Icons.cancel,
                  color: i == 0 ? Colors.white : (r.ok ? Colors.greenAccent : Colors.redAccent),
                  size: i == 0 ? 36 : 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.plate ?? 'Không đọc được biển',
                        style: TextStyle(color: Colors.white, fontSize: i == 0 ? 26 : 15, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${_hms(r.at)}${showGate ? (r.gate == 'in' ? ' · VÀO' : ' · RA') : ''} · ${r.msg}',
                        style: TextStyle(color: Colors.white70, fontSize: i == 0 ? 15 : 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
