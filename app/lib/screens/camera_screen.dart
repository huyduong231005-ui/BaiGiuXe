import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../esp_link.dart';
import '../gate_station.dart';
import '../main.dart' show ManagerHome, prefs;

/// Điện thoại gắn ở cổng, kiêm luôn màn quản lý.
/// Có lượt quẹt thẻ -> hiện camera, GateStation tự chụp + nhận diện -> hiện kết quả 3s -> về màn Quản lý.
/// Camera luôn bật ngầm khi đang ở màn Quản lý để lượt quẹt sau không phải chờ khởi động camera.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.gate, required this.onExit});

  final String gate;
  final VoidCallback onExit;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  static const resultShowTime = Duration(seconds: 3);

  CameraController? cam;
  GateStation? station;
  String? error;
  double zoom = 1, maxZoom = 1;
  bool showCamera = true;
  Timer? _backToManager;

  String get _zoomKey => 'zoom_${widget.gate}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

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
    _backToManager?.cancel();
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

  /// Bắt đầu lượt quẹt -> hiện camera. Xong lượt -> giữ kết quả 3s rồi về màn Quản lý.
  void _onBusy() {
    _backToManager?.cancel();
    if (station!.busy.value) {
      setState(() => showCamera = true);
    } else {
      _backToManager = Timer(resultShowTime, () {
        if (mounted) setState(() => showCamera = false);
      });
    }
  }

  @override
  void dispose() {
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
          Stack(children: [
            ManagerHome(onChangeRole: widget.onExit),
            Positioned(
              right: 16,
              bottom: 96,
              child: FloatingActionButton.small(
                heroTag: 'to-camera',
                tooltip: 'Xem camera',
                onPressed: () => setState(() => showCamera = true),
                child: const Icon(Icons.videocam),
              ),
            ),
          ]),
        ],
      );

  Widget _cameraView() {
    final title = switch (widget.gate) { 'in' => 'Camera cổng vào', 'out' => 'Camera cổng ra', _ => 'Camera cả 2 cổng' };
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
              : Stack(fit: StackFit.expand, children: [
                  Center(child: CameraPreview(cam!)),
                  // Khung ngắm: lấy nét + đo sáng đúng vào vùng giữa này.
                  Center(
                    child: FractionallySizedBox(
                      widthFactor: 0.6,
                      heightFactor: 0.22,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.greenAccent, width: 3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Align(
                          alignment: Alignment.topCenter,
                          child: Text('Đặt biển số vào khung',
                              style: TextStyle(color: Colors.greenAccent, backgroundColor: Colors.black54)),
                        ),
                      ),
                    ),
                  ),
                  Align(alignment: Alignment.topCenter, child: _Banner(station!.status)),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (maxZoom > 1)
                        Container(
                          color: Colors.black54,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(children: [
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
                          ]),
                        ),
                      _Banner(station!.last),
                    ]),
                  ),
                ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final ValueNotifier<String> text;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: text,
        builder: (_, v, _) => Container(
          width: double.infinity,
          color: Colors.black54,
          padding: const EdgeInsets.all(12),
          child: Text(v, style: const TextStyle(color: Colors.white, fontSize: 18)),
        ),
      );
}
