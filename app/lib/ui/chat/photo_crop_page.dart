// 拍完先裁剪(docs/design/settings-ia.md §4.4):输入框的 **＋ › 拍照** 拍完不停在
// 输入框,先停在这一页 —— 拖角或拖框选一块、挑比例、转 90°、重拍,按 ✓ 才把这一
// 块放进输入框;按 ✕ 或系统返回,什么都不留。整张画面没动过时按 ✓ 直接交回原图,
// 不重新编码,画质不掉。
//
// ```
//  ✕                                      ✓      44 玻璃钮,12 见方,6 离顶
//  ╭──────────────────────────────────╮
//  │           │    照片    │          │          contain 居中,框外压暗
//  │   ┌──┐    │  (旋转后)  │    ┌──┐  │          角上 22 的白角标,单指拖
//  │   └──┘    │            │    └──┘  │          框内三分线,框外可整体拖
//  ╰──────────────────────────────────╯
//   [自由] [1:1] [4:3] [16:9]                     8 间距,选中的反白
//        [旋转]  [重拍]
// ```
//
// 照片打不开时整页换成一行说明和「用原图」,不让用户卡在相机和输入框之间。

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/attachments.dart';
import '../../state/photo_crop.dart';
import '../shell/page_frame.dart' show GlassIconButton;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'photo_crop_geometry.dart';

/// 拍照之后打开裁剪页;返回用户确认的那一块(整张没动过时是原图),取消时 null。
Future<DraftAttachment?> showPhotoCropPage(
  BuildContext context, {
  required DraftAttachment photo,
  required Future<DraftAttachment?> Function() retake,
}) {
  return Navigator.of(context).push<DraftAttachment>(
    MaterialPageRoute<DraftAttachment>(
      fullscreenDialog: true,
      builder: (_) => PhotoCropPage(photo: photo, retake: retake),
    ),
  );
}

/// 裁剪页的尺寸;`test/chat/photo_crop_page_test.dart` 和页面注释跟着这几个数走。
abstract final class PhotoCropMetrics {
  /// 屏幕边到玻璃钮、到取景框。
  static const side = 12.0;

  /// 状态栏到顶栏。
  static const top = 6.0;

  /// 角标的臂长。
  static const handle = 22.0;

  /// 角上认拖动的半径(像素)。
  static const touch = 34.0;

  /// 框的最短边(像素),再小就捏不住了。
  static const minEdge = 48.0;
}

class PhotoCropPage extends StatefulWidget {
  const PhotoCropPage({super.key, required this.photo, required this.retake});

  /// 刚拍的那张。
  final DraftAttachment photo;

  /// 重拍:再开一次相机;用户在相机里取消时返回 null。
  final Future<DraftAttachment?> Function() retake;

  @override
  State<PhotoCropPage> createState() => _PhotoCropPageState();
}

class _PhotoCropPageState extends State<PhotoCropPage> {
  late DraftAttachment _photo;
  ui.Image? _picture;
  Object? _decodeError;

  /// 顺时针转过的 90° 个数。
  int _turns = 0;

  /// 选中的比例(宽 / 高);null 是自由。
  double? _ratio;
  Rect _crop = cropUnit;
  bool _busy = false;
  CropCorner? _corner;
  bool _moving = false;
  int _decodeTicket = 0;

  @override
  void initState() {
    super.initState();
    _photo = widget.photo;
    unawaited(_decode());
  }

  @override
  void dispose() {
    _picture?.dispose();
    super.dispose();
  }

  double _aspectOf(ui.Image picture) => turnedAspect(picture.width.toDouble(), picture.height.toDouble(), _turns);

  Future<void> _decode() async {
    final ticket = ++_decodeTicket;
    try {
      final codec = await ui.instantiateImageCodec(_photo.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted || ticket != _decodeTicket) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _picture?.dispose();
        _picture = frame.image;
        _decodeError = null;
        _turns = 0;
        _crop = _ratio == null ? cropUnit : fitCropRatio(cropUnit, _ratio!, _aspectOf(frame.image));
      });
    } catch (error) {
      if (!mounted || ticket != _decodeTicket) return;
      setState(() => _decodeError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final l10n = context.l10n;
    return Theme(
      data: buildDarkTheme(accent: surfaces.accent, glassBlur: surfaces.blurEnabled),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        PhotoCropMetrics.side,
                        PhotoCropMetrics.top,
                        PhotoCropMetrics.side,
                        0,
                      ),
                      child: Row(
                        children: [
                          GlassIconButton(
                            icon: AppIcons.close,
                            tooltip: l10n.commonCancel,
                            onPressed: _busy ? null : () => Navigator.of(context).pop(),
                          ),
                          const Spacer(),
                          GlassIconButton(
                            icon: AppIcons.done,
                            tooltip: l10n.commonDone,
                            onPressed: _picture == null || _busy ? null : _confirm,
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: _stage()),
                    _controls(),
                  ],
                ),
                if (_busy)
                  Positioned.fill(
                    child: ColoredBox(
                      color: const Color(0x59000000),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stage() {
    final picture = _picture;
    if (_decodeError != null) return _unreadable();
    if (picture == null) return const Center(child: CircularProgressIndicator());
    final aspect = _aspectOf(picture);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final photo = photoRectIn(size, aspect);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _grab(details.localPosition, photo),
          onPanUpdate: (details) => _drag(details.delta, photo),
          onPanEnd: (_) => _letGo(),
          onPanCancel: _letGo,
          child: CustomPaint(
            size: size,
            painter: _CropPainter(picture: picture, aspect: aspect, turns: _turns, crop: _crop),
          ),
        );
      },
    );
  }

  Widget _controls() {
    final l10n = context.l10n;
    final on = _picture != null && !_busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(PhotoCropMetrics.side, 12, PhotoCropMetrics.side, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                _Pill(label: l10n.photoCropFree, selected: _ratio == null, onTap: on ? () => _setRatio(null) : null),
                for (final (ratio, label) in const [(1.0, '1:1'), (4 / 3, '4:3'), (16 / 9, '16:9')])
                  _Pill(label: label, selected: _ratio == ratio, onTap: on ? () => _setRatio(ratio) : null),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: [
              _Pill(label: l10n.photoCropRotate, onTap: on ? _rotate : null),
              _Pill(label: l10n.photoCropRetake, onTap: on ? _retake : null),
            ],
          ),
        ],
      ),
    );
  }

  Widget _unreadable() {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.photoCropUnreadable,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 20),
            _Pill(label: l10n.photoCropUseOriginal, onTap: () => Navigator.of(context).pop(_photo)),
          ],
        ),
      ),
    );
  }

  void _grab(Offset at, Rect photo) {
    final point = Offset((at.dx - photo.left) / photo.width, (at.dy - photo.top) / photo.height);
    final radius = PhotoCropMetrics.touch / math.min(photo.width, photo.height);
    _corner = cropCornerAt(_crop, point, radius: radius);
    _moving = _corner == null && _crop.contains(point);
  }

  void _drag(Offset delta, Rect photo) {
    final picture = _picture;
    if (picture == null || _busy) return;
    final step = Offset(delta.dx / photo.width, delta.dy / photo.height);
    final minSize = Offset(
      (PhotoCropMetrics.minEdge / photo.width).clamp(0.02, 0.9).toDouble(),
      (PhotoCropMetrics.minEdge / photo.height).clamp(0.02, 0.9).toDouble(),
    );
    if (_corner case final corner?) {
      setState(
        () => _crop = dragCropCorner(
          _crop,
          corner,
          step,
          ratio: _ratio,
          aspect: _aspectOf(picture),
          minSize: minSize,
        ),
      );
    } else if (_moving) {
      setState(() => _crop = moveCrop(_crop, step));
    }
  }

  void _letGo() {
    _corner = null;
    _moving = false;
  }

  void _setRatio(double? ratio) {
    final picture = _picture;
    if (picture == null) return;
    setState(() {
      _ratio = ratio;
      if (ratio != null) _crop = fitCropRatio(_crop, ratio, _aspectOf(picture));
    });
  }

  void _rotate() {
    final picture = _picture;
    if (picture == null) return;
    setState(() {
      _turns = (_turns + 1) % 4;
      final ratio = _ratio;
      _crop = ratio == null ? cropUnit : fitCropRatio(_crop, ratio, _aspectOf(picture));
    });
  }

  Future<void> _retake() async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = await widget.retake();
    if (!mounted) return;
    if (next == null) {
      setState(() => _busy = false);
      return;
    }
    setState(() {
      _busy = false;
      _photo = next;
    });
    await _decode();
  }

  Future<void> _confirm() async {
    if (_busy || _picture == null) return;
    // 整张没动过:原图交回去,省一次解码和重新编码。
    if (_turns == 0 && _isWholePicture(_crop)) {
      Navigator.of(context).pop(_photo);
      return;
    }
    setState(() => _busy = true);
    final crop = _crop;
    final bytes = await compute(cropPhotoTask, (
      bytes: _photo.bytes,
      left: crop.left,
      top: crop.top,
      width: crop.width,
      height: crop.height,
      quarterTurns: _turns,
    ));
    if (!mounted) return;
    setState(() => _busy = false);
    // 裁失败就用原图:用户按下 ✓ 想要的是「这张图」,不该被解码问题挡住。
    Navigator.of(context).pop(bytes == null ? _photo : DraftAttachment.sniff(croppedPhotoName(_photo.name), bytes));
  }

  static bool _isWholePicture(Rect crop) =>
      crop.left.abs() < 0.001 &&
      crop.top.abs() < 0.001 &&
      (crop.right - 1).abs() < 0.001 &&
      (crop.bottom - 1).abs() < 0.001;
}

/// 一颗胶囊按钮:选中反白,没选中是 14% 的白。
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap, this.selected = false});

  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.quick,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.white : const Color(0x24FFFFFF),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: selected ? Colors.black : (onTap == null ? Colors.white38 : Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({required this.picture, required this.aspect, required this.turns, required this.crop});

  final ui.Image picture;
  final double aspect;
  final int turns;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final photo = photoRectIn(size, aspect);
    _paintPicture(canvas, photo);
    final frame = Rect.fromLTRB(
      photo.left + crop.left * photo.width,
      photo.top + crop.top * photo.height,
      photo.left + crop.right * photo.width,
      photo.top + crop.bottom * photo.height,
    );
    // 框外压暗一半多,框内保持原样。
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(frame),
      ),
      Paint()..color = const Color(0x99000000),
    );
    canvas.drawRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white,
    );
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = const Color(0x59FFFFFF);
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), grid);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), grid);
    }
    final cornerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    for (final (at, sx, sy) in [
      (frame.topLeft, 1.0, 1.0),
      (frame.topRight, -1.0, 1.0),
      (frame.bottomLeft, 1.0, -1.0),
      (frame.bottomRight, -1.0, -1.0),
    ]) {
      final arm = math.min(PhotoCropMetrics.handle, math.min(frame.width, frame.height) / 2);
      canvas.drawLine(at, at.translate(arm * sx, 0), cornerPaint);
      canvas.drawLine(at, at.translate(0, arm * sy), cornerPaint);
    }
  }

  void _paintPicture(Canvas canvas, Rect photo) {
    canvas.save();
    canvas.translate(photo.center.dx, photo.center.dy);
    canvas.rotate(turns * math.pi / 2);
    // 转过奇数个 90° 之后,画布的两轴互换。
    final drawn = turns.isOdd
        ? Rect.fromCenter(center: Offset.zero, width: photo.height, height: photo.width)
        : Rect.fromCenter(center: Offset.zero, width: photo.width, height: photo.height);
    canvas.drawImageRect(
      picture,
      Rect.fromLTWH(0, 0, picture.width.toDouble(), picture.height.toDouble()),
      drawn,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.picture != picture || old.aspect != aspect || old.turns != turns || old.crop != crop;
}
