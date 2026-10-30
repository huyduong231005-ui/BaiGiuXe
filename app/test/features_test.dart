import 'dart:typed_data';

import 'package:bai_giu_xe/lot.dart';
import 'package:bai_giu_xe/nfc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _slot(String code, String state, int row, int col) =>
    {'code': code, 'state': state, 'row': row, 'col': col, 'vehicle_type': 'motorbike', 'active': state != 'off'};

void main() {
  test('uidHex: UID đọc bằng NFC điện thoại cùng định dạng với RC522 ở cổng', () {
    expect(uidHex(Uint8List.fromList([0xA1, 0xB2, 0x0C, 0x04])), 'A1B20C04');
    expect(uidHex(Uint8List.fromList([0x04, 0x5A, 0x1F, 0x22, 0x6B, 0x70, 0x80])), '045A1F226B7080');
  });

  test('vnd: tiền có dấu chấm ngăn nghìn', () {
    expect(vnd(0), '0đ');
    expect(vnd(5000), '5.000đ');
    expect(vnd(1500000), '1.500.000đ');
    expect(vnd(-25000), '-25.000đ');
  });

  testWidgets('sơ đồ bãi: vẽ đủ ô theo khu, chạm ô gọi lại đúng ô', (tester) async {
    final map = {
      'zones': [
        {'id': 1, 'name': 'A', 'vehicle_type': 'motorbike', 'rows': 1, 'cols': 3, 'slots': [
          _slot('A-01', 'resident', 0, 0), _slot('A-02', 'parked', 0, 1), _slot('A-03', 'free', 0, 2),
        ]},
      ],
    };
    String? tapped;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: LotMapView(map, highlight: 'A-03', onSlot: (s) => tapped = s['code'] as String))),
    ));
    expect(find.text('Khu A · Xe máy'), findsOneWidget);
    expect(find.text('1 trống'), findsOneWidget);
    await tester.tap(find.text('03'));
    expect(tapped, 'A-03');
  });
}
