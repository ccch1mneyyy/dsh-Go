import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_code/restore_point.dart';
import 'package:dsh_app/state/voice_model_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui_config/support.dart' show until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtime = MethodChannel('dsh/runtime');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory fixture;
  late Directory data;
  late GuestFs fs;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('harmony-guest-layout-');
    data = Directory('${fixture.path}/engine-data')..createSync();
    for (final child in ['dsh-home', 'agents', 'home']) {
      Directory('${data.path}/$child').createSync();
    }
    fs = GuestFs.harmony(data);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(runtime, null);
    fixture.deleteSync(recursive: true);
  });

  test('鸿蒙只按边界映射三个用户目录，默认构造仍为 Android rootfs', () {
    expect(fs.dir('/root/.dsh').path, '${data.path}/dsh-home');
    expect(fs.dir('/root/.agents').path, '${data.path}/agents');
    expect(fs.file('/root/notes.txt').path, '${data.path}/home/notes.txt');
    expect(fs.file('/root/.dsh-other/notes.txt').path, '${data.path}/home/.dsh-other/notes.txt');
    expect(fs.rootfs, isNull);
    final android = GuestFs(fixture);
    expect(android.file('/root/.dsh/dsh-go/ui.json').path, '${fixture.path}/root/.dsh/dsh-go/ui.json');
    expect(android.rootfs, fixture);
    for (final path in ['/tmp/x', '/etc/x', '/root2/x', 'root/a', '/root/../x',
      '/root/.dsh/../x', '/root//x', '/root/./x', '/root/\\x', '/root/a\u0000b']) {
      expect(() => fs.file(path), throwsArgumentError, reason: path);
      expect(() => fs.dir(path), throwsArgumentError, reason: path);
    }
  });

  test('技能和 AGENTS 导入只读写新建持久目录，不创建虚假 rootfs', () async {
    const skill = SharedSkill(name: 'fixture-skill', files: {
      'SKILL.md': '---\nname: fixture-skill\ndescription: 测试技能\n---\n仅测试。',
      'references/guide.md': '测试参考。',
    });
    await fs.writeSkill(skill);
    await fs.writeImportedAgentsMd('测试用户规则。');
    expect(File('${data.path}/dsh-home/skills/fixture-skill/SKILL.md').readAsStringSync(), skill.files['SKILL.md']);
    expect(File('${data.path}/agents/AGENTS.md').readAsStringSync(), '测试用户规则。');
    expect(fs.readSkill('fixture-skill'), skill.files);
    expect((await fs.readUserSkills()).single.name, 'fixture-skill');
    expect(await fs.readUserAgentsMd(), '测试用户规则。');
    expect(await fs.readImportedAgentsMd(), '测试用户规则。');
    expect(await RestorePoint(fs).pinCurrentProfile(), isFalse);
    expect(() => RestorePoint(fs).lkgFile, throwsUnsupportedError);
    await fs.deleteImportedAgentsMd();
    expect(File('${data.path}/agents/AGENTS.md').existsSync(), isFalse);
    expect(Directory('${data.path}/root').existsSync(), isFalse);
    expect(Directory('${fixture.path}/runtime').existsSync(), isFalse);
  });

  test('只读布局通道不接触凭据，并拒绝缺失和未知布局', () async {
    final calls = <String>[];
    Map<String, Object?>? layout = {'version': 1, 'dataRoot': data.path};
    messenger.setMockMethodCallHandler(runtime, (call) async {
      calls.add(call.method);
      return layout;
    });
    final local = await GuestFs.local(operatingSystem: 'ohos');
    expect(local?.file(GuestFs.importedAgentsMd).path, '${data.path}/agents/AGENTS.md');
    layout = {'version': 2, 'dataRoot': data.path};
    expect(await GuestFs.local(operatingSystem: 'ohos'), isNull);
    layout = {'version': 1, 'dataRoot': '${fixture.path}/absent'};
    expect(await GuestFs.local(operatingSystem: 'ohos'), isNull);
    layout = null;
    expect(await GuestFs.local(operatingSystem: 'ohos'), isNull);
    expect(calls, everyElement('getStorageLayout'));
  });

  test('UI 文件解析使用真实 dsh-home，并保持受管安装和 SenseVoice 不可用', () async {
    final container = ProviderContainer(overrides: [guestFsProvider.overrideWith((_) async => fs)]);
    addTearDown(container.dispose);
    expect(await container.read(uiRootfsResolverProvider)(), isNull);
    final resolve = container.read(uiConfigFileResolverProvider);
    final config = await resolve();
    expect(config?.path, '${data.path}/dsh-home/dsh-go/ui.json');
    expect(await DeviceVoiceModelPlatform(guestFs: () async => fs).files(), isNull);
    expect(await DeviceVoiceModelPlatform(guestFs: () async => GuestFs(fixture)).files(), isNotNull);
    final reads = <UiConfigRead>[];
    final source = LocalUiConfigSource(configFile: resolve, debounce: const Duration(milliseconds: 20));
    final subscription = source.watch().listen(reads.add);
    try {
      await until(() => reads.isNotEmpty);
      config!.writeAsStringSync('{"version":1,"density":"compact"}');
      await until(() => reads.last is UiConfigText);
      expect((reads.last as UiConfigText).text, contains('compact'));
      await source.writeStatus(parseUiConfig((reads.last as UiConfigText).text));
      expect(File('${data.path}/dsh-home/dsh-go/ui.status.json').existsSync(), isTrue);
      expect(Directory('${data.path}/root').existsSync(), isFalse);
    } finally {
      await subscription.cancel();
    }
  });
}
