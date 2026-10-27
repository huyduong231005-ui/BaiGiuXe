import 'package:bai_giu_xe/gate_station.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('cropForOcr cắt đúng vùng giữa theo ocrCrop', () {
    final photo = img.encodeJpg(img.Image(width: 1000, height: 2000));
    final out = img.decodeJpg(cropForOcr(photo))!;
    expect(out.width, (1000 * ocrCrop.w).round());
    expect(out.height, (2000 * ocrCrop.h).round());
  });
}
