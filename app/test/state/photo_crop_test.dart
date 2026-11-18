import 'dart:typed_data';

import 'package:dsh_app/state/photo_crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 左半边红、右半边蓝的 8×4 图:裁一半、转 90° 都能从尺寸和颜色看出来。
Uint8List _picture() {
  final image = img.Image(width: 8, height: 4, numChannels: 4);
  for (final pixel in image) {
    pixel
      ..r = pixel.x < 4 ? 255 : 0
      ..g = 0
      ..b = pixel.x < 4 ? 0 : 255
      ..a = 255;
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('裁右半边:宽减半,颜色是右半边那一块', () {
    final bytes = cropPhotoBytes((bytes: _picture(), left: 0.5, top: 0, width: 0.5, height: 1, quarterTurns: 0));
    expect(bytes, isNotNull);
    final cropped = img.decodeImage(bytes!)!;
    expect(cropped.width, 4);
    expect(cropped.height, 4);
    final pixel = cropped.getPixel(2, 0);
    expect(pixel.b, greaterThan(200));
    expect(pixel.r, lessThan(60));
  });

  test('先转 90° 再裁:两轴互换', () {
    final bytes = cropPhotoBytes((bytes: _picture(), left: 0, top: 0, width: 1, height: 1, quarterTurns: 1));
    final cropped = img.decodeImage(bytes!)!;
    expect(cropped.width, 4);
    expect(cropped.height, 8);
  });

  test('打不开的字节返回 null,不抛错', () {
    expect(
      cropPhotoBytes((bytes: Uint8List.fromList([1, 2, 3]), left: 0, top: 0, width: 1, height: 1, quarterTurns: 0)),
      isNull,
    );
  });

  test('裁完一律叫 .jpg', () {
    expect(croppedPhotoName('IMG_1234.HEIC'), 'IMG_1234.jpg');
    expect(croppedPhotoName('photo'), 'photo.jpg');
  });
}
