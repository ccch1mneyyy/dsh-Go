// 拍完裁剪的字节部分:转 90°、按比例裁一块、限长边、编 JPEG。
//
// 走 `package:image`(纯 Dart),所以整段能丢进 isolate 跑:一张 2.5k 边的手机
// 照片在这里大约 1–2 秒,界面在 `ui/chat/photo_crop_page.dart`,几何在
// `ui/chat/photo_crop_geometry.dart`。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 一块裁剪(0–1 的比例坐标),坐标系是照片顺时针转 [quarterTurns] 个 90° 之后
/// 的画面,和裁剪页上看到的框一致。记录类型可以直接送进 isolate。
typedef PhotoCrop = ({
  Uint8List bytes,
  double left,
  double top,
  double width,
  double height,
  int quarterTurns,
});

/// 长边上限:和 `ImagePicker` 取照片时的 2560 一致,模型看不到更多。
const photoMaxSide = 2560;

/// JPEG 质量:和取照片时的 88 一致。
const photoJpegQuality = 88;

/// [PhotoCrop] → JPEG 字节;照片打不开时返回 null。
Uint8List? cropPhotoBytes(PhotoCrop request) {
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null) return null;
  // 画面按 EXIF 摆正再转:`instantiateImageCodec` 显示时已经摆正过,裁的时候不摆
  // 就会把竖拍的照片裁成横的。没有 EXIF 时这一步原样返回。
  final source = img.bakeOrientation(decoded);
  final turns = request.quarterTurns % 4;
  final turned = turns == 0 ? source : img.copyRotate(source, angle: turns * 90);
  final width = turned.width;
  final height = turned.height;
  final left = (request.left * width).round().clamp(0, width - 1).toInt();
  final top = (request.top * height).round().clamp(0, height - 1).toInt();
  final cropWidth = (request.width * width).round().clamp(1, width - left).toInt();
  final cropHeight = (request.height * height).round().clamp(1, height - top).toInt();
  var cropped = left == 0 && top == 0 && cropWidth == width && cropHeight == height
      ? turned
      : img.copyCrop(turned, x: left, y: top, width: cropWidth, height: cropHeight);
  final longest = math.max(cropped.width, cropped.height);
  if (longest > photoMaxSide) {
    final scale = photoMaxSide / longest;
    cropped = img.copyResize(
      cropped,
      width: math.max(1, (cropped.width * scale).round()),
      height: math.max(1, (cropped.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }
  return img.encodeJpg(cropped, quality: photoJpegQuality);
}

/// [compute] 的入口:单参数,便于换到别的 isolate 上裁。
Uint8List? cropPhotoTask(PhotoCrop request) => cropPhotoBytes(request);

/// 「IMG_1234.HEIC」→「IMG_1234.jpg」:裁完一律是 JPEG。
String croppedPhotoName(String name) {
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name}.jpg';
}
