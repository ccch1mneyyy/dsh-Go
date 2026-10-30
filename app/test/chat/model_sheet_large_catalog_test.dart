// A phone-sized catalog with 60 description-free models. Names and channel
// labels are illustrative test data, not a fetched provider catalog.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart' show withTestFonts;
import 'support/harness.dart';

const _names = [
  'Gemini 2.5 Flash',
  'Gemini 2.5 Flash Lite Preview',
  'Gemini 2.5 Pro',
  'Gemma 3 27B Instruct',
  'Gemma 3 12B Instruct',
  'Gemini Flash Latest',
  'Gemini Flash Lite Latest',
  'Gemini Pro Latest',
  'Gemini 2.0 Flash',
  'Nano Banana Image Preview',
  'Gemini 3 Pro Preview',
  'Gemini 3 Flash Preview',
];

final _models = [
  for (var i = 0; i < 60; i++)
    ModelInfo(
      provider: 'ac',
      id: 'preview-$i',
      name: '${_names[i % _names.length]} · 样例 ${(i + 1).toString().padLeft(2, '0')}',
      efforts: i == 6 || i == 59
          ? const [ReasoningEffort('off', 'Off', null), ReasoningEffort('high', 'High', null)]
          : const [],
      defaultEffort: i == 6 || i == 59 ? 'high' : null,
    ),
];

final _catalog = ModelCatalog(
  defaultSelection: const ModelSelection(provider: 'ac', model: 'preview-6', reasoningEffort: 'high'),
  routableProviders: const ['deepseek-official', 'ac', 'openrouter'],
  groups: [
    ProviderGroup('deepseek-official', 'DeepSeek Account', testCatalog.groups.first.models),
    ProviderGroup('ac', 'ac', _models),
    const ProviderGroup('openrouter', 'openrouter.ai', [
      ModelInfo(provider: 'openrouter', id: 'preview-router', name: 'OpenRouter 示例模型'),
    ]),
  ],
  failures: const [],
);

Finder _card(int index) => find.byKey(ValueKey('ac\u0000preview-$index'));

Finder get _scrollable => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down),
);

Future<ChatHarness> _open(WidgetTester tester, {double scale = 1}) async {
  usePhoneView(tester);
  tester.view.physicalSize = const Size(780, 1728);
  tester.view.padding = const FakeViewPadding(top: 80, bottom: 40);
  tester.view.viewPadding = const FakeViewPadding(top: 80, bottom: 40);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  mockClipboard(tester);
  final harness = ChatHarness(
    session: 's1',
    states: {'s1': ChatState(loading: false, model: _catalog.defaultSelection)},
    catalog: _catalog,
  );
  final theme = buildDarkTheme(accent: AppAccent.graphite);
  await tester.pumpWidget(
    testApp(
      Theme(
        data: withTestFonts(theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: const [cjkFamily]))),
        child: const ChatScreen(),
      ),
      brightness: Brightness.dark,
      overrides: harness.overrides,
    ),
  );
  await pumpFrames(tester, 6);
  await tester.tap(find.byType(ModelChip));
  await pumpFrames(tester, 8);
  return harness;
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
    chatClock = () => DateTime(2026, 10, 31, 1, 39);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('60 models without descriptions wrap and the last model can be selected (text ×$scale)', (
      tester,
    ) async {
      final harness = await _open(tester, scale: scale);
      expect(_models.every((model) => model.description == null), isTrue);
      final first = tester.getRect(_card(0));
      final second = tester.getRect(_card(1));
      expect(first.left, second.left);
      expect(second.top - first.bottom, moreOrLessEquals(12));
      for (var i = 0; i < _models.length; i++) {
        final name = find.descendant(of: _card(i), matching: find.text(_models[i].name));
        expect(tester.renderObject<RenderParagraph>(name).didExceedMaxLines, isFalse, reason: _models[i].name);
      }
      await tester.scrollUntilVisible(_card(59), 500, scrollable: _scrollable);
      await pumpFrames(tester, 4);
      await tester.tap(_card(59));
      await pumpFrames(tester, 4);
      expect(harness.controllers['s1']!.models.last.model, 'preview-59');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('golden 60 models without descriptions: top, middle and bottom', (tester) async {
    await _open(tester);
    final viewport = tester.getRect(_scrollable);
    final fullyVisible = List.generate(60, _card).where((finder) {
      final rect = tester.getRect(finder);
      return rect.top >= viewport.top && rect.bottom <= viewport.bottom;
    }).length;
    final position = tester.state<ScrollableState>(_scrollable).position;
    debugPrint(
      'Large catalog: $fullyVisible complete cards on first screen; scroll extent ${position.maxScrollExtent}.',
    );
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/model_sheet_large_top_dark.png'));
    await tester.scrollUntilVisible(_card(29), 500, scrollable: _scrollable);
    await pumpFrames(tester, 4);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/model_sheet_large_middle_dark.png'));
    await tester.scrollUntilVisible(find.byType(ManageModelsLink), 500, scrollable: _scrollable);
    await pumpFrames(tester, 4);
    expect(find.byType(ManageModelsLink).hitTestable(), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/model_sheet_large_bottom_dark.png'));
    expect(tester.takeException(), isNull);
  });
}
