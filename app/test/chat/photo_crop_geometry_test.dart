import 'dart:ui';

import 'package:dsh_app/ui/chat/photo_crop_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('1:1 在 4:3 的画面上是中间最大的方框', () {
    final crop = fitCropRatio(cropUnit, 1, 4 / 3);
    expect(crop.width, closeTo(1, 1e-9));
    expect(crop.height, closeTo(0.75, 1e-9));
    expect(crop.center.dx, closeTo(0.5, 1e-9));
    expect(crop.center.dy, closeTo(0.5, 1e-9));
  });

  test('自由拖右下角:左上角不动,框不翻转也不出画', () {
    final crop = dragCropCorner(
      const Rect.fromLTWH(0.2, 0.2, 0.5, 0.5),
      CropCorner.bottomRight,
      const Offset(0.6, 0.9),
      aspect: 1,
      minSize: const Offset(0.05, 0.05),
    );
    expect(crop.topLeft, const Offset(0.2, 0.2));
    expect(crop.right, lessThanOrEqualTo(1));
    expect(crop.bottom, lessThanOrEqualTo(1));
  });

  test('带比例拖角:对着的角不动,比例不变', () {
    final crop = dragCropCorner(
      const Rect.fromLTWH(0.1, 0.1, 0.4, 0.4),
      CropCorner.bottomRight,
      const Offset(0.1, 0.05),
      ratio: 4 / 3,
      aspect: 1,
      minSize: const Offset(0.05, 0.05),
    );
    expect(crop.topLeft, const Offset(0.1, 0.1));
    expect(crop.width / crop.height, closeTo(4 / 3, 1e-9));
    expect(crop.right, lessThanOrEqualTo(1));
  });

  test('整体拖动停在画面里', () {
    final crop = moveCrop(const Rect.fromLTWH(0.5, 0.5, 0.5, 0.5), const Offset(0.4, -0.9));
    expect(crop, const Rect.fromLTWH(0.5, 0, 0.5, 0.5));
  });

  test('角上 34 像素内认拖动,框中间不算角', () {
    const crop = Rect.fromLTWH(0.25, 0.25, 0.5, 0.5);
    const radius = 34 / 400;
    expect(cropCornerAt(crop, const Offset(0.26, 0.26), radius: radius), CropCorner.topLeft);
    expect(cropCornerAt(crop, const Offset(0.5, 0.5), radius: radius), isNull);
  });
}
