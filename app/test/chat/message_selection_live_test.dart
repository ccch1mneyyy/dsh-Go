// A message still being written selects like a finished one (long-press,
// double tap), though what streams in reaches the selection only once a
// finger comes down on it or the writing stops: each delta would otherwise
// make the region sort the whole reply's pieces again.

import 'package:dsh_app/ui/chat/widgets/message_selection.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _words = 'alpha beta gamma';

Widget _message(String text, {required bool live}) => testApp(
  Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: MessageSelection(
        text: text,
        live: live,
        onMore: () {},
        child: Text(text, key: const ValueKey('text')),
      ),
    ),
  ),
);

List<String> _clipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  return copied;
}

/// A reply being written: it grows over a few deltas, nobody touching it.
Future<void> _stream(WidgetTester tester) async {
  for (final text in ['alpha', 'alpha beta', _words]) {
    await tester.pumpWidget(_message(text, live: true));
    await tester.pump(const Duration(milliseconds: 32));
  }
}

/// Everything the region would select and copy now (its select-all and
/// copy shortcuts).
Future<void> _copyAll(WidgetTester tester) async {
  final inside = tester.element(find.byKey(const ValueKey('text')));
  Actions.invoke(inside, const SelectAllTextIntent(SelectionChangedCause.keyboard));
  await tester.pump();
  Actions.invoke(inside, CopySelectionTextIntent.copy);
  await tester.pump();
}

/// A finger held down, frames coming at the display's pace as on a phone
/// (`tester.longPress` jumps the clock past the long-press in one frame).
Future<void> _hold(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at);
  for (var held = Duration.zero; held < kLongPressTimeout * 1.2; held += const Duration(milliseconds: 16)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
}

Future<void> _copyFromToolbar(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '复制'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('a long-press on a reply being written selects the word under the finger', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    await _hold(tester, tester.getCenter(find.byKey(const ValueKey('text'))));
    await _copyFromToolbar(tester);
    expect(copied, ['beta']);
  });

  testWidgets('so does a double tap', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    final at = tester.getCenter(find.byKey(const ValueKey('text')));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at);
    await _copyFromToolbar(tester);
    expect(copied, ['beta']);
  });

  testWidgets('or once the keyboard reaches it: its select-all and copy shortcuts', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, [_words]);
  });

  testWidgets('what streams in reaches the selection once a finger comes down', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    await _copyAll(tester);
    expect(copied, isEmpty, reason: 'nobody has touched it: the deltas were held back');

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('text'))));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    await _copyAll(tester);
    expect(copied, [_words]);

    // From then on, what streams in goes straight through.
    await tester.pumpWidget(_message('$_words delta', live: true));
    await tester.pump();
    await _copyAll(tester);
    expect(copied.last, '$_words delta');
  });

  testWidgets('or once the writing stops', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    await tester.pumpWidget(_message(_words, live: false));
    await tester.pump();
    await _copyAll(tester);
    expect(copied, [_words]);
  });

  testWidgets('holding a selection handle at the edge extends into offscreen lines', (tester) async {
    usePhoneView(tester);
    final text = List.generate(80, (i) => 'token line $i').join('\n');
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final list = find.byType(ListView);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: SizedBox(
              height: 320,
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [MessageSelection(text: text, child: Text(text))],
              ),
            ),
          ),
        ),
      ),
    );
    final view = tester.getRect(list);
    final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
    final start = text.indexOf('token line 5\n');
    final word = TextSelection(baseOffset: start, extentOffset: start + 'token'.length);
    final box = paragraph.getBoxesForSelection(word).single.toRect();
    await _hold(tester, paragraph.localToGlobal(box.center));
    await tester.pumpAndSettle();
    expect(paragraph.selections.single, word);
    final belowFirstPage = paragraph.getPositionForOffset(paragraph.globalToLocal(view.bottomLeft)).offset;

    final handle = paragraph.localToGlobal(box.bottomRight + const Offset(1, 5));
    final drag = await tester.startGesture(handle);
    await drag.moveBy(const Offset(0, 30));
    await drag.moveTo(Offset(handle.dx, view.bottom - 12));
    for (var frame = 0; frame < 48; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.offset, greaterThan(180));
    expect(paragraph.selections.single.start, word.start);
    expect(paragraph.selections.single.end, greaterThan(belowFirstPage));
    final releasedAt = controller.offset;
    final selected = paragraph.selections.single;
    await drag.up();
    await tester.pumpAndSettle();
    expect(controller.offset - releasedAt, inInclusiveRange(0, 24));
    expect(paragraph.selections.single, selected);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a finished message is selectable from the start', (tester) async {
    final copied = _clipboard(tester);
    await tester.pumpWidget(_message(_words, live: false));
    await tester.pump();
    await _copyAll(tester);
    expect(copied, [_words]);
  });
}
