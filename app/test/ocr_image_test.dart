import 'package:bai_giu_xe/gate_station.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('shrinkForOcr giữ cả khung hình, chỉ thu nhỏ cạnh dài về ocrMaxSide', () {
    final out = img.decodeJpg(shrinkForOcr(img.encodeJpg(img.Image(width: 1080, height: 1920))))!;
    expect(out.height, ocrMaxSide);
    expect(out.width, 1080 * ocrMaxSide ~/ 1920);
  });

  test('ảnh nhỏ hơn ocrMaxSide giữ nguyên kích thước', () {
    final out = img.decodeJpg(shrinkForOcr(img.encodeJpg(img.Image(width: 640, height: 480))))!;
    expect((out.width, out.height), (640, 480));
  });
}
