// A long tool output is clipped in the chat row and whole on its own page.

import 'package:dsh_app/ui/chat/output_page.dart';
import 'package:dsh_app/ui/chat/render/ansi_text.dart';
import 'package:dsh_app/ui/chat/render/long_text.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

String _numbered(int lines) => [for (var i = 1; i <= lines; i++) 'line $i'].join('\n');

/// Everything on screen as text: plain and rich text, and selectable text.
String _shown(WidgetTester tester) => [
  ...tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()),
  ...tester.widgetList<SelectableText>(find.byType(SelectableText)).map((w) => w.data ?? w.textSpan!.toPlainText()),
].join('\n');

Widget _detail(String result, {String name = 'bash', Map<String, Object?> args = const {'command': 'make'}}) => testApp(
  Scaffold(
    body: SingleChildScrollView(
      child: ToolDetail(view: ToolView.of(tool('a', name, args, result: result))),
    ),
  ),
);

void main() {
  setUpAll(loadTestFonts);

  group('clipLongText', () {
    test('ordinary output is left whole', () {
      final text = _numbered(kClipHeadLines + kClipTailLines);
      final clip = clipLongText(text);
      expect(clip.clipped, isFalse);
      expect(clip.head, same(text));
      expect(clip.totalLines, kClipHeadLines + kClipTailLines);
    });

    test('many lines keep whole lines of the head and the tail', () {
      final clip = clipLongText(_numbered(5000));
      expect(clip.clipped, isTrue);
      expect(clip.totalLines, 5000);
      expect(clip.head.split('\n'), [for (var i = 1; i <= kClipHeadLines; i++) 'line $i']);
      expect(clip.tail!.split('\n'), [for (var i = 5000 - kClipTailLines + 1; i <= 5000; i++) 'line $i']);
      expect(clip.hiddenLines, 5000 - kClipHeadLines - kClipTailLines);
    });

    test('head, hidden part and tail add up to the text', () {
      for (final text in [_numbered(5000), 'x' * 100000, '${'y' * 9000}\n${_numbered(900)}\n${'z' * 30000}']) {
        final clip = clipLongText(text);
        expect(clip.clipped, isTrue);
        final head = text.startsWith('${clip.head}\n') ? clip.head.length + 1 : clip.head.length;
        expect(head + clip.hiddenChars + clip.tail!.length, text.length);
        expect(text.endsWith(clip.tail!), isTrue);
        expect(clip.head.length + clip.tail!.length, lessThanOrEqualTo(kClipMaxChars));
      }
    });

    test('one enormous line is cut by characters', () {
      final clip = clipLongText('x' * 2000000);
      expect(clip.totalLines, 1);
      expect(clip.hiddenLines, 0);
      expect(clip.hiddenChars, 2000000 - kClipMaxChars);
    });

    test('a cut never lands inside an escape sequence or a surrogate pair', () {
      // Every position in the long line is the start of an escape or an emoji half.
      final coloured = '\x1B[38;2;10;20;30mab' * 20000;
      final clip = clipLongText(coloured);
      expect(stripAnsi(clip.head), matches(RegExp(r'^(ab)*$')));
      expect(stripAnsi(clip.tail!), matches(RegExp(r'^(ab)*$')));

      final emoji = clipLongText('😀' * 60000);
      expect(emoji.head.runes.every((r) => r == 0x1F600), isTrue);
      expect(emoji.tail!.runes.every((r) => r == 0x1F600), isTrue);
    });
  });

  test('parseAnsiLines carries a colour over line breaks', () {
    const base = TextStyle(color: Color(0xFF000000));
    final palette = [for (var i = 0; i < 16; i++) Color(0xFF000000 + i * 16)];
    final lines = parseAnsiLines('plain\n\x1B[31mred\nstill red\x1B[0m\nplain again', base, palette);
    Color? colourOf(int line) => (lines[line].children!.first as TextSpan).style!.color;
    expect(lines, hasLength(4));
    expect(lines.map((l) => l.toPlainText()), ['plain', 'red', 'still red', 'plain again']);
    expect(colourOf(0), base.color);
    expect(colourOf(1), palette[1]);
    expect(colourOf(2), palette[1]);
    expect(colourOf(3), base.color);
  });

  testWidgets('ordinary output has no clip marker and no view-all bar', (tester) async {
    await tester.pumpWidget(_detail(_numbered(40)));
    expect(find.text('查看全部'), findsNothing);
    expect(_shown(tester), contains('line 40'));
    expect(_shown(tester), isNot(contains('省略')));
  });

  testWidgets('long output lays out only its head and tail, and opens whole', (tester) async {
    mockClipboard(tester);
    final output = _numbered(5000);
    await tester.pumpWidget(_detail(output));

    final shown = _shown(tester);
    expect(shown, contains('line 1\n'));
    expect(shown, contains('line 5000'));
    expect(shown, isNot(contains('line 2500')));
    expect(find.text('中间省略 4,800 行'), findsOneWidget);
    expect(
      find.text('共 5,000 行 · ${output.length ~/ 1000},${'${output.length % 1000}'.padLeft(3, '0')} 字'),
      findsOneWidget,
    );

    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(find.byType(OutputPage), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.text('line 1', findRichText: true), findsOneWidget);
    // Rows are built as they scroll into view, not all 5000 at once.
    expect(find.text('line 2500', findRichText: true), findsNothing);

    await tester.tap(find.byTooltip('跳到末尾'));
    await tester.pumpAndSettle();
    expect(find.text('line 5000', findRichText: true), findsOneWidget);
    expect(find.byTooltip('回到开头'), findsOneWidget);
    await tester.tap(find.byTooltip('回到开头'));
    await tester.pumpAndSettle();
    expect(find.text('line 1', findRichText: true), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.tap(find.byTooltip('复制全文'));
    await tester.pump();
    expect(copied, output);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the gap marker opens the full page too', (tester) async {
    await tester.pumpWidget(_detail(_numbered(3000)));
    await tester.ensureVisible(find.text('中间省略 2,800 行'));
    await tester.pump();
    await tester.tap(find.text('中间省略 2,800 行'));
    await tester.pumpAndSettle();
    expect(find.byType(OutputPage), findsOneWidget);
  });

  testWidgets('a long command is clipped but keeps its prompt', (tester) async {
    final command = _numbered(2000);
    await tester.pumpWidget(_detail('ok', args: {'command': command}));
    expect(_shown(tester), contains(r'$ line 1'));
    expect(find.text('中间省略 1,800 行'), findsOneWidget);
    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(find.text('命令'), findsOneWidget);
    // The prompt is decoration: the full page (and its copy) is the command itself.
    expect(tester.widget<OutputPage>(find.byType(OutputPage)).text, command);
  });

  testWidgets('the full page splits one enormous line into rows', (tester) async {
    final text = 'x' * 50000;
    await tester.pumpWidget(testApp(OutputPage(title: '输出', text: text)));
    await tester.pump();
    expect(find.text('共 1 行 · 50,000 字'), findsOneWidget);
    final longest = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText().length)
        .reduce((a, b) => a > b ? a : b);
    expect(longest, lessThanOrEqualTo(4000));
  });

  testWidgets('the full page keeps ANSI colours and copies plain text', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.pumpWidget(
      testApp(const OutputPage(title: '输出', text: 'ok\n\x1B[31mfailed\nhere\x1B[0m', ansi: true)),
    );
    await tester.pump();
    expect(find.text('failed', findRichText: true), findsOneWidget);
    expect(find.textContaining('\x1B', findRichText: true), findsNothing);
    await tester.tap(find.byTooltip('复制全文'));
    await tester.pump();
    expect(copied, 'ok\nfailed\nhere');
    await tester.pump(const Duration(seconds: 5));
  });
}
