import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'logic.dart';

// Phải trùng với SVC_UUID / EVT_UUID / CMD_UUID trong firmware/src/main.cpp.
final svcUuid = Guid('8f3c0001-2b6e-4d1a-9c55-6b61e2a7c001');
final evtUuid = Guid('8f3c0001-2b6e-4d1a-9c55-6b61e2a7c002'); // ESP32 -> ĐT (notify)
final cmdUuid = Guid('8f3c0001-2b6e-4d1a-9c55-6b61e2a7c003'); // ĐT -> ESP32 (write)

/// Kết nối BLE tới ESP32, tự kết nối lại khi rớt. Bản tin hai chiều là JSON một dòng.
class EspLink {
  final status = ValueNotifier<String>('Dang tim ESP32...');
  final _events = StreamController<Rec>.broadcast();
  Stream<Rec> get events => _events.stream;

  /// Gọi mỗi lần vừa kết nối xong (gửi giờ, số chỗ trống...).
  VoidCallback? onConnected;

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _cmd;
  bool _stopped = false;

  void start() => _loop();

  Future<void> _loop() async {
    while (!_stopped) {
      try {
        final dev = await _connectOnce();
        await dev.connectionState.firstWhere((s) => s == BluetoothConnectionState.disconnected);
      } catch (e) {
        status.value = 'Loi BLE: $e';
      }
      _cmd = null;
      if (_stopped) break;
      if (!status.value.startsWith('Loi')) status.value = 'Mat ket noi ESP32, dang thu lai...';
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  Future<BluetoothDevice> _connectOnce() async {
    status.value = 'Dang tim ESP32...';
    await FlutterBluePlus.adapterState.firstWhere((s) => s == BluetoothAdapterState.on);
    final found = Completer<BluetoothDevice>();
    final scanSub = FlutterBluePlus.onScanResults.listen((rs) {
      if (rs.isNotEmpty && !found.isCompleted) found.complete(rs.first.device);
    });
    try {
      await FlutterBluePlus.startScan(withServices: [svcUuid], timeout: const Duration(seconds: 15));
      final dev = await found.future.timeout(const Duration(seconds: 16),
          onTimeout: () => throw TimeoutException('Khong thay ESP32 (bat Bluetooth, dung gan ESP32)'));
      _dev = dev;
      await FlutterBluePlus.stopScan();
      status.value = 'Dang ket noi ESP32...';
      await dev.connect(timeout: const Duration(seconds: 10)); // Android tự xin MTU 512
      final svc = (await dev.discoverServices()).firstWhere((s) => s.uuid == svcUuid);
      final evt = svc.characteristics.firstWhere((c) => c.uuid == evtUuid);
      _cmd = svc.characteristics.firstWhere((c) => c.uuid == cmdUuid);
      final sub = evt.onValueReceived.listen(_onNotify);
      dev.cancelWhenDisconnected(sub);
      await evt.setNotifyValue(true);
      status.value = 'Da ket noi ESP32';
      onConnected?.call();
      return dev;
    } finally {
      await scanSub.cancel();
    }
  }

  void _onNotify(List<int> v) {
    try {
      _events.add(jsonDecode(utf8.decode(v)) as Rec);
    } catch (e) {
      debugPrint('[ble] ban tin loi: $e | ${utf8.decode(v, allowMalformed: true)}');
    }
  }

  bool get connected => _cmd != null;

  Future<void> send(Rec msg) async {
    final c = _cmd;
    if (c == null) throw StateError('Chua ket noi ESP32');
    await c.write(utf8.encode(jsonEncode(msg)));
  }

  Future<void> stop() async {
    _stopped = true;
    await FlutterBluePlus.stopScan();
    await _dev?.disconnect();
  }
}
