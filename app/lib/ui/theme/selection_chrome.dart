// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show TickerCanceled;

import 'glass.dart';
import 'shapes.dart';

/// 选择手柄的边长。Material 默认是 22,这里放大一点更好按,也留得下内衬。
const glassSelectionHandleSize = 26.0;

/// 玻璃质感的选择手柄。
///
/// 形状与 Material 相同(圆 + 左上象限的方块,再按选区方向旋转),所以框架
/// 用的 [TextSelectionControls.getHandleAnchor] 锚点语义原样成立;换掉的是
/// 画法:主色渐变、白色内衬、顶部反光和一圈柔影,出现时轻轻弹一下。
final TextSelectionControls glassSelectionControls = _GlassSelectionControls();

class _GlassSelectionControls extends TextSelectionControls with TextSelectionHandleControls {
  @override
  Size getHandleSize(double textLineHeight) => const Size(glassSelectionHandleSize, glassSelectionHandleSize);

  @override
  Widget buildHandle(BuildContext context, TextSelectionHandleType type, double textLineHeight, [VoidCallback? onTap]) {
    final Widget handle = _GlassHandle(onTap: onTap);
    return switch (type) {
      TextSelectionHandleType.left => Transform.rotate(angle: math.pi / 2, child: handle),
      TextSelectionHandleType.right => handle,
      TextSelectionHandleType.collapsed => Transform.rotate(angle: math.pi / 4, child: handle),
    };
  }

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) => switch (type) {
    TextSelectionHandleType.collapsed => const Offset(glassSelectionHandleSize / 2, -4),
    TextSelectionHandleType.left => const Offset(glassSelectionHandleSize, 0),
    TextSelectionHandleType.right => Offset.zero,
  };
}

class _GlassHandle extends StatefulWidget {
  const _GlassHandle({this.onTap});

  final VoidCallback? onTap;

  @override
  State<_GlassHandle> createState() => _GlassHandleState();
}

class _GlassHandleState extends State<_GlassHandle> with SingleTickerProviderStateMixin {
  /// 入场后轻呼吸两下，停在一点常亮的辉光上。只呼吸有限次：无限循环会让
  /// 任何 pumpAndSettle 永远等不到静止。
  late final _breath = AnimationController(vsync: this, duration: _pulseStep, value: 0.3);

  static const _pulseStep = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    unawaited(_pulse());
  }

  Future<void> _pulse() async {
    try {
      for (var i = 0; i < 2; i++) {
        await _breath.animateTo(1, duration: _pulseStep, curve: Curves.easeOut).orCancel;
        await _breath.animateTo(0.3, duration: _pulseStep, curve: Curves.easeIn).orCancel;
      }
    } on TickerCanceled {
      // 手柄先消失：呼吸到此为止。
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = TextSelectionTheme.of(context).selectionHandleColor ?? scheme.primary;
    return TweenAnimationBuilder<double>(
      // 和工具栏的淡入同一个节拍:先小一号,再弹到位。
      tween: Tween(begin: 0.72, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: SizedBox.square(
        dimension: glassSelectionHandleSize,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          child: CustomPaint(
            painter: _GlassHandlePainter(color, dark: scheme.brightness == Brightness.dark, breath: _breath),
          ),
        ),
      ),
    );
  }
}

class _GlassHandlePainter extends CustomPainter {
  _GlassHandlePainter(this.color, {required this.dark, required this.breath}) : super(repaint: breath);

  final Color color;
  final bool dark;
  final Animation<double> breath;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final path = Path()
      ..addOval(Rect.fromCircle(center: Offset(radius, radius), radius: radius))
      ..addRect(Rect.fromLTWH(0, 0, radius, radius));

    // 呼吸辉光：压在形状外面一圈同色柔光，随动画变亮变宽。
    final glow = breath.value;
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: (dark ? 0.20 : 0.15) * glow)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 3 * glow),
    );

    // 柔影:玻璃是浮在字上的,不是贴上去的。
    canvas.drawPath(
      path.shift(const Offset(0, 1.4)),
      Paint()
        ..color = Colors.black.withValues(alpha: dark ? 0.34 : 0.24)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.6),
    );

    // 主体:同色系里由亮到深的斜向渐变。浅色主题不能往白里提 —— 手柄压在
    // 白页面和气泡上,提亮会把轮廓洗掉(对比度掉到 2.6:1);深色反过来要提亮。
    final body = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        dark ? Color.lerp(color, Colors.white, 0.38)! : color,
        dark ? color : Color.lerp(color, Colors.black, 0.18)!,
      ],
    );
    canvas.drawPath(path, Paint()..shader = body.createShader(Offset.zero & size));

    // 内衬:白色发丝边,玻璃的边必须亮一下。
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: dark ? 0.50 : 0.70),
    );

    // 顶部反光:只在形状内部的一片椭圆,压住边缘会脏。
    canvas.save();
    canvas.clipPath(path);
    canvas.drawOval(
      Rect.fromCircle(center: Offset(radius * 0.92, radius * 0.74), radius: radius * 0.46),
      Paint()
        ..color = Colors.white.withValues(alpha: dark ? 0.26 : 0.34)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassHandlePainter oldDelegate) => oldDelegate.color != color || oldDelegate.dark != dark;
}

/// 选中文字后的操作条：内容还是框架的 [TextSelectionToolbarTextButton]，
/// 定位和溢出交给 [TextSelectionToolbar]；换掉的只有外层那张 Material 卡片。
Widget glassSelectionToolbar(TextSelectionToolbarAnchors anchors, List<ContextMenuButtonItem> items) {
  if (items.isEmpty) return const SizedBox.shrink();
  return TextSelectionToolbar(
    anchorAbove: anchors.primaryAnchor,
    anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
    toolbarBuilder: (context, child) =>
        GlassSurface(tier: GlassTier.chrome, borderRadius: AppShape.radiusLg, child: child),
    children: [
      for (var i = 0; i < items.length; i++)
        TextSelectionToolbarTextButton(
          padding: TextSelectionToolbarTextButton.getPadding(i, items.length),
          onPressed: items[i].onPressed,
          child: Text(items[i].label ?? ''),
        ),
    ],
  );
}
