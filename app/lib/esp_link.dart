import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'logic.dart';

const mqttHost = String.fromEnvironment('MQTT_HOST');
const mqttUser = String.fromEnvironment('MQTT_USER');
const mqttPass = String.fromEnvironment('MQTT_PASS');

// Phải trùng với T_EVT / T_CMD / T_ESP / T_PHONE trong firmware/src/main.cpp.
const evtTopic = 'bgx/evt'; // ESP32 -> ĐT
const cmdTopic = 'bgx/cmd'; // ĐT -> ESP32
const espTopic = 'bgx/esp'; // "1"/"0" (retained + LWT): ESP32 có đang online không
String phoneTopic(String gate) => 'bgx/phone/$gate'; // "1"/"0" (retained + LWT): ĐT của cổng này
// Chế độ nhận thẻ (retained): mốc ms epoch tới lúc đó màn Thêm thẻ đang chờ quẹt, "0" = tắt. Trong lúc này
// ĐT camera bỏ qua lượt quẹt (không chụp, không gọi API, không báo "thẻ chưa đăng ký").
const enrollTopic = 'bgx/enroll';

/// Có cấu hình MQTT lúc build (--dart-define-from-file=dart_defines.json) không.
bool get mqttConfigured => mqttHost.isNotEmpty;

/// Kết nối tới ESP32 qua MQTT broker (EMQX Cloud, TLS), tự kết nối lại khi rớt.
/// ĐT dùng WiFi hay 4G đều được. Bản tin hai chiều là JSON một dòng.
class EspLink {
  /// [presence] false: chỉ nghe / gửi bản tin (màn Thêm thẻ), không báo ESP32 là có ĐT ở cổng.
  EspLink(this.gate, {this.presence = true});

  final String gate; // 'in' | 'out' | 'both': báo cho ESP32 biết cổng nào đã có ĐT
  final bool presence;
  final status = ValueNotifier<String>('Dang ket noi may chu...');
  final _events = StreamController<Rec>.broadcast();
  Stream<Rec> get events => _events.stream;

  /// Gọi mỗi lần thấy ESP32 online (gửi giờ, số chỗ trống...).
  VoidCallback? onConnected;

  /// Màn Thêm thẻ (máy này hoặc máy khác) đang chờ quẹt thẻ.
  bool get enrolling => DateTime.now().millisecondsSinceEpoch < _enrollUntil;
  int _enrollUntil = 0;

  late final _c = MqttServerClient.withPort(mqttHost, 'bgx-$gate-${DateTime.now().microsecondsSinceEpoch}', 8883);
  bool _espOnline = false;
  bool _stopped = false;

  void start() => _connect();

  Future<void> _connect() async {
    _c
      ..secure = true
      ..keepAlivePeriod = 20
      ..autoReconnect = true
      ..logging(on: false)
      ..onAutoReconnect = _offline
      ..onAutoReconnected = _online
      ..connectionMessage = presence
          ? (MqttConnectMessage()
              .withWillTopic(phoneTopic(gate))
              .withWillMessage('0')
              .withWillRetain()
              .withWillQos(MqttQos.atLeastOnce)
              .startClean())
          : MqttConnectMessage().startClean();
    // autoReconnect chỉ lo các lần rớt sau; lần đầu phải tự thử lại.
    while (!_stopped) {
      try {
        await _c.connect(mqttUser, mqttPass);
        break;
      } catch (e) {
        status.value = 'Loi ket noi may chu: $e';
        _c.disconnect();
        await Future.delayed(const Duration(seconds: 5));
      }
    }
    if (_stopped) return;
    _c.updates!.listen((msgs) {
      for (final m in msgs) {
        final s = utf8.decode((m.payload as MqttPublishMessage).payload.message, allowMalformed: true);
        switch (m.topic) {
          case espTopic:
            _setEsp(s == '1');
          case enrollTopic:
            _enrollUntil = int.tryParse(s) ?? 0;
          default:
            _onEvt(s);
        }
      }
    });
    _c.subscribe(evtTopic, MqttQos.atMostOnce);
    _c.subscribe(espTopic, MqttQos.atLeastOnce);
    _c.subscribe(enrollTopic, MqttQos.atLeastOnce);
    _online();
  }

  /// Bật chế độ nhận thẻ tới [until] (null = tắt) cho mọi ĐT camera.
  void setEnroll(DateTime? until) {
    if (_c.connectionStatus?.state != MqttConnectionState.connected) return;
    _publish(enrollTopic, '${until?.millisecondsSinceEpoch ?? 0}', retain: true);
  }

  void _online() {
    if (presence) _publish(phoneTopic(gate), '1', retain: true);
    if (!_espOnline) status.value = 'Cho ESP32 ket noi mang...';
  }

  void _offline() {
    _espOnline = false; // kết nối lại sẽ nhận lại bgx/esp (retained) -> đồng bộ lại ESP32
    status.value = 'Mat mang, dang ket noi lai...';
  }

  void _setEsp(bool on) {
    if (on == _espOnline) return;
    _espOnline = on;
    status.value = on ? 'Da ket noi ESP32' : 'ESP32 mat mang (kiem tra WiFi bai xe)';
    if (on) onConnected?.call();
  }

  void _onEvt(String s) {
    try {
      _events.add(jsonDecode(s) as Rec);
    } catch (e) {
      debugPrint('[mqtt] ban tin loi: $e | $s');
    }
  }

  void _publish(String topic, String s, {bool retain = false}) {
    final b = MqttClientPayloadBuilder()..addUTF8String(s);
    _c.publishMessage(topic, MqttQos.atLeastOnce, b.payload!, retain: retain);
  }

  bool get connected => _espOnline && _c.connectionStatus?.state == MqttConnectionState.connected;

  Future<void> send(Rec msg) async {
    if (!connected) throw StateError('Chua ket noi ESP32');
    _publish(cmdTopic, jsonEncode(msg));
  }

  Future<void> stop() async {
    _stopped = true;
    // Ngắt chủ động thì broker không gửi LWT, nên tự báo offline trước.
    if (presence && _c.connectionStatus?.state == MqttConnectionState.connected) _publish(phoneTopic(gate), '0', retain: true);
    _c.disconnect();
  }
}
