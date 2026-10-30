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

  testWidgets('mặt bằng: vẽ được cổng, đường, ô; chạm vào ô gọi lại đúng ô', (tester) async {
    final map = {
      'layout': ['#I###O#', '#=====#', '#AA.CC#', '#######'],
      'zones': [
        {'id': 1, 'name': 'A', 'vehicle_type': 'motorbike', 'slots': [_slot('A-01', 'resident', 2, 1), _slot('A-02', 'free', 2, 2)]},
        {'id': 2, 'name': 'C', 'vehicle_type': 'car', 'slots': [_slot('C-01', 'parked', 2, 4), _slot('C-02', 'free', 2, 5)]},
      ],
    };
    String? tapped;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          child: LotPlanView(map,
              zoomable: false,
              route: cellsFrom([[0, 1], [1, 1], [1, 2], [2, 2]]),
              highlight: 'A-02',
              onSlot: (s) => tapped = s['code'] as String),
        ),
      ),
    ));
    expect(find.byType(CustomPaint), findsWidgets);
    // Ô C-02 ở hàng 2, cột 5: mỗi ô rộng 100px
    final plan = find.descendant(of: find.byType(LotPlanView), matching: find.byType(GestureDetector));
    await tester.tapAt(tester.getTopLeft(plan) + const Offset(550, 250));
    expect(tapped, 'C-02');
  });

  test('cellsFrom: đường đi từ API thành danh sách ô', () {
    expect(cellsFrom([[0, 1], [1, 1]]), [(0, 1), (1, 1)]);
    expect(cellsFrom(null), isEmpty);
  });
}
