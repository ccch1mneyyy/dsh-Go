// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';

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

class _GlassHandle extends StatelessWidget {
  const _GlassHandle({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = TextSelectionTheme.of(context).selectionHandleColor ?? scheme.primary;
    return TweenAnimationBuilder<double>(
      // 和工具栏的淡入同一个节拍:先小一号,再弹到位。
      tween: const Tween(begin: 0.72, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: SizedBox.square(
        dimension: glassSelectionHandleSize,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: onTap,
          child: CustomPaint(painter: _GlassHandlePainter(color, dark: scheme.brightness == Brightness.dark)),
        ),
      ),
    );
  }
}

class _GlassHandlePainter extends CustomPainter {
  _GlassHandlePainter(this.color, {required this.dark});

  final Color color;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final path = Path()
      ..addOval(Rect.fromCircle(center: Offset(radius, radius), radius: radius))
      ..addRect(Rect.fromLTWH(0, 0, radius, radius));

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
