// 裁剪页的几何:裁剪框一律用 0–1 的比例坐标表示(整张画面 = [cropUnit]),这一层
// 只算框、不碰像素、也不碰 widget,便于单测。

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 裁剪框的四角。
enum CropCorner { topLeft, topRight, bottomLeft, bottomRight }

/// 整张画面。
const cropUnit = Rect.fromLTWH(0, 0, 1, 1);

/// 画面顺时针转 [turns] 个 90° 之后的宽 / 高。
double turnedAspect(double width, double height, int turns) => turns.isOdd ? height / width : width / height;

/// [size] 里按 [aspect](宽 / 高)居中的画面矩形。
Rect photoRectIn(Size size, double aspect) {
  var width = size.width;
  var height = width / aspect;
  if (height > size.height) {
    height = size.height;
    width = height * aspect;
  }
  return Rect.fromCenter(center: size.center(Offset.zero), width: width, height: height);
}

/// 把 [crop] 换成一个 [ratio](宽 / 高,像素)的最大框,中心不动。
Rect fitCropRatio(Rect crop, double ratio, double aspect) {
  final normalized = ratio / aspect;
  final double width;
  final double height;
  if (normalized >= 1) {
    width = 1;
    height = 1 / normalized;
  } else {
    width = normalized;
    height = 1;
  }
  return _inside(Rect.fromCenter(center: crop.center, width: width, height: height));
}

/// 拖动 [corner] 之后的框。[delta] 是 0–1 坐标里的位移;给了 [ratio] 就保持该
/// 宽 / 高比(像素),对着的角不动;[minSize] 是允许的最小宽高;框不出画面。
Rect dragCropCorner(
  Rect crop,
  CropCorner corner,
  Offset delta, {
  double? ratio,
  required double aspect,
  required Offset minSize,
}) {
  if (ratio == null) {
    var left = crop.left;
    var top = crop.top;
    var right = crop.right;
    var bottom = crop.bottom;
    switch (corner) {
      case CropCorner.topLeft:
        left += delta.dx;
        top += delta.dy;
      case CropCorner.topRight:
        right += delta.dx;
        top += delta.dy;
      case CropCorner.bottomLeft:
        left += delta.dx;
        bottom += delta.dy;
      case CropCorner.bottomRight:
        right += delta.dx;
        bottom += delta.dy;
    }
    left = left.clamp(0.0, math.max(0.0, right - minSize.dx)).toDouble();
    top = top.clamp(0.0, math.max(0.0, bottom - minSize.dy)).toDouble();
    right = right.clamp(math.min(1.0, left + minSize.dx), 1.0).toDouble();
    bottom = bottom.clamp(math.min(1.0, top + minSize.dy), 1.0).toDouble();
    return Rect.fromLTRB(left, top, right, bottom);
  }
  // 保持比例:对着的角不动,先把被拖的角换算成宽高,再按比例补齐,最后整体缩到画面内。
  final (anchor, moving) = switch (corner) {
    CropCorner.topLeft => (crop.bottomRight, crop.topLeft + delta),
    CropCorner.topRight => (crop.bottomLeft, crop.topRight + delta),
    CropCorner.bottomLeft => (crop.topRight, crop.bottomLeft + delta),
    CropCorner.bottomRight => (crop.topLeft, crop.bottomRight + delta),
  };
  final normalized = ratio / aspect;
  final sx = moving.dx >= anchor.dx ? 1.0 : -1.0;
  final sy = moving.dy >= anchor.dy ? 1.0 : -1.0;
  var width = math.max((moving.dx - anchor.dx).abs(), minSize.dx);
  var height = math.max((moving.dy - anchor.dy).abs(), minSize.dy);
  if (width / height > normalized) {
    height = width / normalized;
  } else {
    width = height * normalized;
  }
  final maxWidth = sx > 0 ? 1 - anchor.dx : anchor.dx;
  final maxHeight = sy > 0 ? 1 - anchor.dy : anchor.dy;
  final scale = math.min(1.0, math.min(maxWidth / width, maxHeight / height));
  width *= scale;
  height *= scale;
  return Rect.fromLTWH(sx > 0 ? anchor.dx : anchor.dx - width, sy > 0 ? anchor.dy : anchor.dy - height, width, height);
}

/// 整体拖动 [crop];[delta] 是 0–1 坐标里的位移,框不出画面。
Rect moveCrop(Rect crop, Offset delta) => _inside(crop.shift(delta));

/// [point] 落在哪个角上(都是 0–1 坐标,[radius] 也是);不在角上返回 null。
CropCorner? cropCornerAt(Rect crop, Offset point, {double radius = 0.07}) {
  CropCorner? hit;
  var best = radius;
  for (final (corner, at) in [
    (CropCorner.topLeft, crop.topLeft),
    (CropCorner.topRight, crop.topRight),
    (CropCorner.bottomLeft, crop.bottomLeft),
    (CropCorner.bottomRight, crop.bottomRight),
  ]) {
    final distance = math.max((point.dx - at.dx).abs(), (point.dy - at.dy).abs());
    if (distance <= best) {
      best = distance;
      hit = corner;
    }
  }
  return hit;
}

/// 框平移回画面里。
Rect _inside(Rect rect) => Rect.fromLTWH(
  rect.left.clamp(0.0, (1 - rect.width).clamp(0.0, 1.0)).toDouble(),
  rect.top.clamp(0.0, (1 - rect.height).clamp(0.0, 1.0)).toDouble(),
  rect.width,
  rect.height,
);
