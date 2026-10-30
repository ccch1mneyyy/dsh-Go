import 'package:dsh_app/ui/common/model_icon.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches original IDs, namespaces, case and Chinese names', () {
    expect(modelIconBrand('DeepSeek-AI/DEEPSEEK-V4', 'V4'), 'deepseek');
    expect(modelIconBrand('qwen/qwen3-coder', '代码模型'), 'qwen');
    expect(modelIconBrand('custom-model', '通义千问'), 'qwen');
    expect(modelIconBrand('moonshot-v1-32k', '自定义名称'), 'kimi');
    expect(modelIconBrand('custom-model', '智谱 GLM'), 'zhipu');
    expect(modelIconBrand('eleven_multilingual_v2', 'Speech'), 'elevenlabs');
  });

  test('ID wins over a renamed label; an unknown ID falls back to the name', () {
    expect(modelIconBrand('claude-sonnet', 'DeepSeek'), 'claude');
    expect(modelIconBrand('my-model', 'DeepSeek V4'), 'deepseek');
    expect(modelIconBrand('my-model', 'My model'), isNull);
  });

  test('specific models win over overlapping brand and distillation names', () {
    expect(modelIconBrand('deepseek-r1-distill-qwen-32b', ''), 'deepseek');
    expect(modelIconBrand('ChatGLM-6B', ''), 'chatglm');
    expect(modelIconBrand('zhipu/cogview-4', ''), 'cogview');
    expect(modelIconBrand('MiniMax-Hailuo-02', ''), 'hailuo');
    expect(modelIconBrand('openai/sora', ''), 'sora');
  });

  test('short names match token/version boundaries without substring collisions', () {
    expect(modelIconBrand('01-ai/Yi-34B', ''), 'yi');
    expect(modelIconBrand('Ling2.5', ''), 'ling');
    expect(modelIconBrand('Kling-2.1', ''), 'kling');
    expect(modelIconBrand('tongyi', ''), 'qwen');
    expect(modelIconBrand('openai/o3-mini', ''), 'openai');
    expect(modelIconBrand('gateway_seedream_4', ''), 'doubao');
    expect(modelIconBrand('gateway_step_3', ''), 'stepfun');
    for (final id in ['daily-model', 'darling', 'nano1', 'audio', 'metadata']) {
      expect(modelIconBrand(id, ''), isNull, reason: id);
    }
  });

  testWidgets('loads the correct local artwork in both themes', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          themeAnimationDuration: Duration.zero,
          home: const Center(
            child: ModelIcon(id: 'gpt-5', name: 'GPT'),
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      final theme = brightness == Brightness.dark ? 'dark' : 'light';
      final provider = image.image as ResizeImage;
      expect((provider.imageProvider as AssetImage).assetName, 'assets/model_icons/$theme/openai.png');
      await tester.runAsync(() => precacheImage(image.image, tester.element(find.byType(ModelIcon))));
      await tester.pump();
      expect(tester.getSize(find.byType(ModelIcon)), const Size(20, 20));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('unknown models retain the default glyph', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: ModelIcon(id: 'unknown', name: 'Custom'),
        ),
      ),
    );
    expect(find.byIcon(AppIcons.model), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a failed asset falls back to the same default glyph', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultAssetBundle(
          bundle: _MissingPngBundle(),
          child: const Center(
            child: ModelIcon(id: 'deepseek-v4', name: 'DeepSeek'),
          ),
        ),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    await tester.runAsync(
      () => precacheImage(image.image, tester.element(find.byType(ModelIcon)), onError: (error, stack) {}),
    );
    await tester.pump();
    expect(find.byIcon(AppIcons.model), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _MissingPngBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) =>
      key.endsWith('.png') ? Future.error(StateError('Missing artwork')) : rootBundle.load(key);
}
