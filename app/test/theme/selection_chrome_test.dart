// 玻璃手柄:几何沿用 Material(锚点语义不变),换的是画法和出现时的一点点动画。
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

Widget _app(Widget child) => MaterialApp(
  theme: buildLightTheme(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUpAll(loadTestFonts);

  test('the handle is large enough to hit and keeps the Material anchors', () {
    expect(glassSelectionControls.getHandleSize(18), const Size(glassSelectionHandleSize, glassSelectionHandleSize));
    expect(glassSelectionHandleSize, greaterThan(22));

    expect(
      glassSelectionControls.getHandleAnchor(TextSelectionHandleType.left, 18),
      const Offset(glassSelectionHandleSize, 0),
    );
    expect(glassSelectionControls.getHandleAnchor(TextSelectionHandleType.right, 18), Offset.zero);
    expect(
      glassSelectionControls.getHandleAnchor(TextSelectionHandleType.collapsed, 18),
      const Offset(glassSelectionHandleSize / 2, -4),
    );
  });

  testWidgets('every handle direction builds', (tester) async {
    for (final type in TextSelectionHandleType.values) {
      await tester.pumpWidget(
        _app(Builder(builder: (context) => glassSelectionControls.buildHandle(context, type, 18))),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: type.name);
    }
  });
}
