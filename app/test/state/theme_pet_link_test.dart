// The theme ↔ pet link: selecting a theme that carries an installed pet picks
// it and remembers what was showing; leaving the theme puts that back. A
// person's own choice while the theme is active wins, and 「不显示」 is never
// opened behind their back — the settings row offers it instead.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_state.dart' show noPetId;
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/theme_pet_link.dart';
import 'package:dsh_app/themes/theme_library.dart';
import 'package:dsh_app/themes/theme_pack.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Uint8List _themeZip() => _zip({
  'theme.json': utf8.encode(
    jsonEncode({
      'schema': 2,
      'id': 'xmas',
      'name': '圣诞雪夜',
      'pet': {'id': _petId, 'name': '雪独角鲸'},
    }),
  ),
  'pet.zip': _zip({
    'pack.json': utf8.encode(jsonEncode(_fixtureJson())),
    for (final entry in _fixtureSheets().entries) entry.key: entry.value,
  }),
});

void main() {
  late Directory temp;
  late PetLibrary pets;
  late ThemeLibrary themes;
  late File themeZip;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'pet.pack': defaultPetId});
    temp = Directory.systemTemp.createTempSync('theme-pet-link');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    themes = ThemeLibrary(() async => Directory('${temp.path}/themes'), pets: pets);
    themeZip = File('${temp.path}/theme.zip')..writeAsBytesSync(_themeZip());
    await themes.install(themeZip);
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        petLibraryProvider.overrideWithValue(pets),
        themeLibraryProvider.overrideWithValue(themes),
      ],
    );
    addTearDown(c.dispose);
    c.read(themePetLinkProvider);
    return c;
  }

  Future<void> ready(ProviderContainer c) async {
    await c.read(petPrefsProvider.notifier).ready;
    await c.read(themePetLinkProvider.notifier).settled;
  }

  Future<void> select(ProviderContainer c, String? id) async {
    if (id != null) await c.read(themePackByIdProvider(id).future);
    await c.read(appearanceProvider.notifier).selectThemePack(id);
    await c.read(themePetLinkProvider.notifier).settled;
  }

  test('selecting a pet theme picks its pet and leaving puts the old one back', () async {
    final c = container();
    await ready(c);
    expect(c.read(petPrefsProvider).packId, defaultPetId);

    await select(c, 'user-xmas');
    expect(c.read(petPrefsProvider).packId, _petId);
    expect(c.read(themePetLinkProvider)?.themeId, 'user-xmas');
    expect(c.read(themePetLinkProvider)?.previousPetId, defaultPetId);

    await select(c, null);
    expect(c.read(petPrefsProvider).packId, defaultPetId);
    expect(c.read(themePetLinkProvider), isNull);
  });

  test('「不显示」 is not opened by selecting the theme; 使用配套宠物 does that', () async {
    final c = container();
    await ready(c);
    await c.read(petPrefsProvider.notifier).setPack(noPetId);
    await c.read(themePetLinkProvider.notifier).settled;

    await select(c, 'user-xmas');
    expect(c.read(petPrefsProvider).packId, noPetId, reason: 'no pet was showing; the theme does not force one');
    expect(c.read(themePetLinkProvider), isNull);

    final pack = c.read(activeThemePackProvider)!;
    c.read(themePetLinkProvider.notifier).useBundledPet(pack);
    await c.read(themePetLinkProvider.notifier).settled;
    expect(c.read(petPrefsProvider).packId, _petId);
    expect(c.read(themePetLinkProvider)?.previousPetId, noPetId);

    await select(c, null);
    expect(c.read(petPrefsProvider).packId, noPetId);
    expect(c.read(themePetLinkProvider), isNull);
  });

  test('a pet chosen while the theme is active is not replaced when the theme leaves', () async {
    final c = container();
    await ready(c);
    await select(c, 'user-xmas');
    expect(c.read(petPrefsProvider).packId, _petId);

    await c.read(petPrefsProvider.notifier).setPack('pink-fish');
    await c.read(themePetLinkProvider.notifier).settled;
    expect(c.read(themePetLinkProvider), isNull, reason: 'the person changed the pet by hand');

    await select(c, null);
    expect(c.read(petPrefsProvider).packId, 'pink-fish');
  });

  test('a pet already chosen before the theme is not claimed by it', () async {
    final c = container();
    await ready(c);
    await c.read(petPrefsProvider.notifier).setPack(_petId);
    await c.read(themePetLinkProvider.notifier).settled;

    await select(c, 'user-xmas');
    expect(c.read(themePetLinkProvider), isNull);
    await select(c, null);
    expect(c.read(petPrefsProvider).packId, _petId, reason: 'the theme did not choose it, so it does not take it away');
  });

  test('the link and the choice survive a restart, and the old pet comes back later', () async {
    SharedPreferences.setMockInitialValues({'pet.pack': defaultPetId});
    final first = ProviderContainer(
      overrides: [
        petLibraryProvider.overrideWithValue(pets),
        themeLibraryProvider.overrideWithValue(themes),
      ],
    );
    first.read(themePetLinkProvider);
    await ready(first);
    await select(first, 'user-xmas');
    expect(first.read(petPrefsProvider).packId, _petId);
    first.dispose();

    final second = ProviderContainer(
      overrides: [
        petLibraryProvider.overrideWithValue(pets),
        themeLibraryProvider.overrideWithValue(themes),
      ],
    );
    addTearDown(second.dispose);
    second.read(themePetLinkProvider);
    await ready(second);
    expect(second.read(appearanceProvider).themePackId, 'user-xmas');
    expect(second.read(petPrefsProvider).packId, _petId);
    expect(second.read(themePetLinkProvider)?.previousPetId, defaultPetId);

    await select(second, null);
    expect(second.read(petPrefsProvider).packId, defaultPetId);
    expect(second.read(themePetLinkProvider), isNull);
  });

  test('a pet that disappeared while the theme was active restores the default, not a dead id', () async {
    final c = container();
    await ready(c);
    // A brought pet is the previous pet, then disappears before the theme leaves.
    final other = File('${temp.path}/other.zip')
      ..writeAsBytesSync(
        _zip({
          'pack.json': utf8.encode(jsonEncode({..._fixtureJson(), 'id': 'other', 'name': '另一只'})),
          for (final entry in _fixtureSheets().entries) entry.key: entry.value,
        }),
      );
    await pets.install(other, replaceExisting: true);
    await c.read(petPrefsProvider.notifier).setPack('user-other');
    await c.read(themePetLinkProvider.notifier).settled;

    await select(c, 'user-xmas');
    expect(c.read(petPrefsProvider).packId, _petId);
    expect(c.read(themePetLinkProvider)?.previousPetId, 'user-other');

    await pets.remove('user-other');
    await select(c, null);
    expect(c.read(petPrefsProvider).packId, defaultPetId);
  });
}
