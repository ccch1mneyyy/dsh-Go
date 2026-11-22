// Settings › appearance › theme packs with a bundled pet: the import preflight
// asks before replacing an installed pet (cancel writes nothing), a confirmed
// import installs the pet with the theme and applies both, and 「使用配套宠物」
// is the only way the pet comes on when 「不显示」 was chosen.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_state.dart' show noPetId;
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:dsh_app/state/theme_pet_link.dart';
import 'package:dsh_app/themes/theme_library.dart';
import 'package:dsh_app/ui/settings/appearance/theme_packs_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pets/support.dart' show testTheme;

const _fixture = 'test/fixtures/pets/xmas-narwhal';
const _petId = 'user-xmas-narwhal';

Map<String, Object?> _fixtureJson() =>
    jsonDecode(File('$_fixture/pack.json').readAsStringSync()) as Map<String, Object?>;

Map<String, Uint8List> _fixtureSheets() {
  final json = _fixtureJson();
  final animations = json['animations'] as Map<String, Object?>;
  final names = {for (final animation in animations.values) (animation as Map)['sheet'] as String};
  return {for (final name in names) name: File('$_fixture/$name').readAsBytesSync()};
}

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) => archive.add(ArchiveFile.bytes(name, bytes)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _petZip({String? name}) => _zip({
  'pack.json': utf8.encode(jsonEncode({..._fixtureJson(), 'name': ?name})),
  for (final entry in _fixtureSheets().entries) entry.key: entry.value,
});

Uint8List _themeZip() => _zip({
  'theme.json': utf8.encode(
    jsonEncode({
      'schema': 2,
      'id': 'xmas',
      'name': '圣诞雪夜',
      'pet': {'id': _petId, 'name': '雪独角鲸'},
    }),
  ),
  'pet.zip': _petZip(),
});

void main() {
  late Directory temp;
  late PetLibrary pets;
  late ThemeLibrary themes;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('theme-pet-ui');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    themes = ThemeLibrary(() async => Directory('${temp.path}/themes'), pets: pets);
  });

  File zipFile(String name) => File('${temp.path}/$name')..writeAsBytesSync(_themeZip());

  String? installedPetName() {
    final file = File('${temp.path}/pets/$_petId/pack.json');
    if (!file.existsSync()) return null;
    return (jsonDecode(file.readAsStringSync()) as Map<String, Object?>)['name'] as String?;
  }

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<ProviderContainer> open(WidgetTester tester, File zip) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(390 * 2, 2600 * 2);
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        petLibraryProvider.overrideWithValue(pets),
        themeLibraryProvider.overrideWithValue(themes),
        themePackPickerProvider.overrideWithValue(() async => zip),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: testTheme(Brightness.light),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
          home: const Scaffold(
            body: SingleChildScrollView(child: ThemePacksSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container.read(themePetLinkProvider); // as the app shell keeps it alive
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump();
    return container;
  }

  testWidgets('importing over an installed pet asks first; cancelling changes nothing', (tester) async {
    SharedPreferences.setMockInitialValues({'pet.pack': defaultPetId});
    await tester.runAsync(() async {
      await pets.install(File('${temp.path}/old.zip')..writeAsBytesSync(_petZip(name: '旧雪独角鲸')));
    });
    final zip = zipFile('theme.zip');
    final container = await open(tester, zip);

    await tester.tap(find.text('导入主题包 (.zip)'));
    await settle(tester, () => find.text('宠物已存在').evaluate().isNotEmpty);
    expect(find.text('宠物已存在'), findsOneWidget);
    expect(find.textContaining('宠物「雪独角鲸」已存在，导入会替换它。'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await settle(tester, () => find.text('宠物已存在').evaluate().isEmpty);
    expect(find.text('宠物已存在'), findsNothing);
    expect(installedPetName(), '旧雪独角鲸');
    expect(Directory('${temp.path}/themes/user-xmas').existsSync(), isFalse);
    expect(container.read(appearanceProvider).themePackId, isNull);
    expect(zip.existsSync(), isFalse, reason: 'the picked copy is tidied away on cancel too');
  });

  testWidgets('confirming installs the pet and theme, applies both, and the row names the pet', (tester) async {
    SharedPreferences.setMockInitialValues({'pet.pack': defaultPetId});
    await tester.runAsync(() async {
      await pets.install(File('${temp.path}/old.zip')..writeAsBytesSync(_petZip(name: '旧雪独角鲸')));
    });
    final container = await open(tester, zipFile('theme.zip'));

    await tester.tap(find.text('导入主题包 (.zip)'));
    await settle(tester, () => find.text('宠物已存在').evaluate().isNotEmpty);
    await tester.tap(find.text('确认'));
    await settle(tester, () => container.read(petPrefsProvider).packId == _petId);
    await settle(tester, () => find.text('圣诞雪夜').evaluate().isNotEmpty);

    expect(container.read(appearanceProvider).themePackId, 'user-xmas');
    expect(installedPetName(), '雪独角鲸');
    expect(container.read(petPrefsProvider).packId, _petId);
    expect(container.read(themePetLinkProvider)?.previousPetId, defaultPetId);
    expect(find.text('圣诞雪夜'), findsOneWidget);
    expect(find.textContaining('含宠物 雪独角鲸'), findsOneWidget);
    expect(Directory('${temp.path}/pets/$_petId').existsSync(), isTrue);

    // The same zip again replaces both: one dialog says so.
    zipFile('theme.zip');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('导入主题包 (.zip)'));
    await settle(tester, () => find.text('宠物已存在').evaluate().isNotEmpty);
    expect(find.textContaining('宠物「雪独角鲸」已存在，导入会替换它。'), findsOneWidget);
    expect(find.textContaining('同名主题也会被替换。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester, () => find.text('宠物已存在').evaluate().isEmpty);
  });

  testWidgets('「不显示」 stays off after import; 使用配套宠物 turns the pet on and leaving turns it off', (tester) async {
    SharedPreferences.setMockInitialValues({'pet.pack': noPetId});
    final container = await open(tester, zipFile('theme.zip'));

    await tester.tap(find.text('导入主题包 (.zip)'));
    await settle(tester, () => container.read(appearanceProvider).themePackId == 'user-xmas');
    await settle(tester, () => find.text('使用配套宠物「雪独角鲸」').evaluate().isNotEmpty);
    expect(container.read(petPrefsProvider).packId, noPetId);

    final usePet = find.text('使用配套宠物「雪独角鲸」');
    expect(usePet, findsOneWidget);
    await tester.tap(usePet);
    await settle(tester, () => container.read(petPrefsProvider).packId == _petId);
    expect(container.read(petPrefsProvider).packId, _petId);
    expect(find.text('使用配套宠物「雪独角鲸」'), findsNothing);

    await tester.tap(find.text('晨雾玻璃（默认）'));
    await settle(
      tester,
      () => container.read(appearanceProvider).themePackId == null &&
          container.read(petPrefsProvider).packId == noPetId,
    );
    expect(container.read(petPrefsProvider).packId, noPetId);
  });

  testWidgets('用对话创建主题 starts a new chat with the theme-maker skill', (tester) async {
    final container = await open(tester, zipFile('theme.zip'));
    expect(find.text('用对话创建主题'), findsOneWidget);
    expect(find.textContaining('告诉 AI 你想要的风格'), findsOneWidget);
    await tester.tap(find.text('用对话创建主题'));
    await tester.pump();
    final pending = container.read(composeInboxProvider);
    expect(pending, isNotEmpty);
    expect(pending.first.text, '/theme-maker ');
  });
}
