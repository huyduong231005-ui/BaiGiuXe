import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api.dart';
import '../esp_link.dart';
import '../gate_station.dart';
import '../lot.dart';
import '../main.dart' show ManagerHome, prefs;

/// Render free ngủ sau 15 phút không có request; ping định kỳ để lượt quẹt thẻ không phải chờ API thức dậy.
const _keepApiAwake = Duration(minutes: 10);

/// Điện thoại gắn ở cổng, kiêm luôn màn quản lý.
/// Màn camera ở lại liên tục để quét xe xếp hàng: mỗi lượt quẹt, GateStation tự chụp + nhận diện,
/// kết quả mới nhất hiện to, vài xe trước xếp bên dưới. Đang ở màn Quản lý mà có lượt quẹt -> tự về camera.
/// Camera luôn bật ngầm khi đang ở màn Quản lý để lượt quẹt sau không phải chờ khởi động camera.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.gate, required this.onExit});

  final String gate;
  final VoidCallback onExit;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  static const historyShown = 4;

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
    if (state == AppLifecycleState.inactive && cam != null) {
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
    cam?.dispose();
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
  Widget build(BuildContext context) => IndexedStack(
    index: showCamera ? 0 : 1,
    children: [
      _cameraView(),
      ManagerHome(onChangeRole: widget.onExit, onShowCamera: () => setState(() => showCamera = true)),
    ],
  );

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
          TextButton.icon(
            onPressed: () => setState(() => showCamera = false),
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
                // Chỉ đường cho xe vừa vào: mặt bằng + đường từ cổng tới ô, chữ to để tài xế / bảo vệ đọc.
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 44),
                    child: ValueListenableBuilder(
                      valueListenable: station!.guide,
                      builder: (_, g, _) => g == null
                          ? const SizedBox.shrink()
                          : Card(
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              color: Colors.black.withValues(alpha: 0.82),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  Text('Mời vào ô ${g.route['slot']}',
                                      style: const TextStyle(color: Colors.yellowAccent, fontSize: 26, fontWeight: FontWeight.bold)),
                                  Text(g.route['hint'] as String, textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.white, fontSize: 15)),
                                  const SizedBox(height: 8),
                                  LotPlanView(g.map,
                                      route: cellsFrom(g.route['path']),
                                      highlight: g.route['slot'] as String?,
                                      zoomable: false,
                                      maxHeight: MediaQuery.of(context).size.height * 0.28),
                                ]),
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
    builder: (_, v, _) => Container(
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
