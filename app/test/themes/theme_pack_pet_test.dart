// A theme pack may carry one brought pet: the schema-2 `pet` block plus an
// optional `pet.zip`. These tests hold the contract the app and the Workshop
// rely on: old schema-1 packs still read, a pet is not mistaken for an unknown
// field, the pet's installed id (not its pack id) is what theme.json names,
// and a bundled pet does not widen the theme archive's size limits.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/pets/pet_ids.dart';
import 'package:dsh_app/pets/pet_pack_validator.dart';
import 'package:dsh_app/themes/theme_pack.dart';
import 'package:dsh_app/themes/theme_pack_validator.dart';
import 'package:flutter_test/flutter_test.dart';

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

Uint8List _fixturePetZip() => _zip({
  'pack.json': utf8.encode(jsonEncode(_fixtureJson())),
  for (final entry in _fixtureSheets().entries) entry.key: entry.value,
});

/// A small schema-1 pet pack, for cases where the art is irrelevant.
Map<String, Object?> _petPack({String id = 'xmas-narwhal', String sheet = 'idle.png'}) => {
  'schema': 1,
  'id': id,
  'name': '雪独角鲸',
  'canvas': {'w': 16, 'h': 16},
  'contentBox': {'x': 0, 'y': 0, 'w': 16, 'h': 16},
  'animations': {
    'idle': {
      'sheet': sheet,
      'frameW': 16,
      'frameH': 16,
      'cols': 1,
      'box': {'x': 0, 'y': 0, 'w': 16, 'h': 16},
      'frames': [
        {'i': 0, 'ms': 200},
      ],
    },
  },
  'states': {
    'idle': ['idle'],
  },
};

Uint8List _petZip({Map<String, Object?>? json, Map<String, List<int>> sheets = const {}}) {
  final pack = json ?? _petPack();
  return _zip({
    'pack.json': utf8.encode(jsonEncode(pack)),
    if (sheets.isEmpty)
      'idle.png': File('$_fixture/idle.png').readAsBytesSync()
    else
      for (final entry in sheets.entries) entry.key: entry.value,
  });
}

Map<String, Object?> _themeJson({
  int schema = themePackSchema,
  Object? pet = const {'id': _petId, 'name': '雪独角鲸'},
  String? font,
  String? font2,
  String? image,
}) => {
  'schema': schema,
  'id': 'xmas',
  'name': '圣诞雪夜',
  'pet': ?pet,
  if (image != null) 'surfaces': {'backdropImage': image},
  if (font != null) 'typography': {'uiFont': font, 'readingFont': ?font2},
};

Uint8List _themeZip(Map<String, Object?> json, {Uint8List? pet, Map<String, List<int>> files = const {}}) => _zip({
  'theme.json': utf8.encode(jsonEncode(json)),
  'pet.zip': ?pet,
  for (final entry in files.entries) entry.key: entry.value,
});

Matcher _failsWith(String code) => throwsA(isA<ThemeValidationException>().having((e) => e.code, 'code', code));

void main() {
  test('schema 2 names the installed pet id and round-trips; schema 1 stays petless', () {
    final pack = ThemePack.parse(_themeJson());
    expect(pack.pet, const ThemePetRef(id: _petId, name: '雪独角鲸'));
    final json = pack.toJson();
    expect(json['schema'], 2);
    expect(json['pet'], {'id': _petId, 'name': '雪独角鲸'});
    expect(ThemePack.parse(json), pack);

    final legacy = ThemePack.parse({'schema': 1, 'id': 'ink', 'name': '墨卷'});
    expect(legacy.pet, isNull);
    expect(legacy.toJson()['schema'], 1);
    expect(legacy.toJson().containsKey('pet'), isFalse);

    // A pet's display name is optional; the archive check fills it from pack.json.
    final unnamed = ThemePack.parse({
      'schema': 2,
      'id': 'xmas',
      'name': '圣诞雪夜',
      'pet': {'id': _petId},
    });
    expect(unnamed.pet!.name, isNull);
    expect(unnamed.toJson()['pet'], {'id': _petId});
  });

  test('pet requires schema 2, and a newer schema says the app is too old', () {
    expect(() => ThemePackValidator.validateParts(_themeJson(schema: 1), const {}), _failsWith('theme-schema'));
    expect(() => ThemePackValidator.validateParts(_themeJson(schema: 3), const {}), _failsWith('theme-schema-version'));
    expect(
      () => ThemePackValidator.validateParts({..._themeJson(pet: null), 'schema': 3}, const {}),
      _failsWith('theme-schema-version'),
    );
    // The old failure mode the schema bump avoids: `pet` is not an unknown field.
    expect(
      () => ThemePackValidator.validateParts({..._themeJson(), 'familiar': 'cat'}, const {}),
      _failsWith('theme-schema'),
    );
    expect(
      () => ThemePackValidator.validateParts(
        _themeJson(pet: const {'id': _petId, 'name': '雪独角鲸', 'sound': 'jingle'}),
        const {},
      ),
      _failsWith('theme-schema'),
    );
    expect(
      () => ThemePackValidator.validateParts(_themeJson(pet: const {'id': 'xmas-narwhal'}), const {}),
      _failsWith('theme-schema'),
    );
  });

  test('a theme zip with a matching pet.zip validates and keeps the pet bytes', () {
    final pet = _fixturePetZip();
    final named = ThemePackValidator.validateArchive(
      _themeZip(_themeJson(pet: const {'id': _petId, 'name': '雪独角鲸'}), pet: pet),
    );
    expect(named.pack.pet!.id, _petId);
    expect(named.pack.pet!.name, '雪独角鲸');
    expect(named.petZip, isNotNull);
    expect(named.json['pet'], {'id': _petId, 'name': '雪独角鲸'});

    // The name is optional; the pet pack's own name fills it in.
    final unnamed = ThemePackValidator.validateArchive(_themeZip(_themeJson(pet: const {'id': _petId}), pet: pet));
    expect(unnamed.pack.pet!.name, '雪独角鲸');
    expect(unnamed.json['pet'], {'id': _petId, 'name': '雪独角鲸'});
  });

  test('pet.zip must exist when declared, and must not ride without a pet block', () {
    expect(() => ThemePackValidator.validateArchive(_themeZip(_themeJson())), _failsWith('theme-pet-missing'));
    expect(
      () => ThemePackValidator.validateArchive(_themeZip(_themeJson(pet: null), pet: _fixturePetZip())),
      _failsWith('theme-pet-unexpected'),
    );
  });

  test("pet.id is the pet's installed id, not its pack.json id", () {
    expect(
      () => ThemePackValidator.validateArchive(
        _themeZip(_themeJson(pet: const {'id': 'user-other'}), pet: _fixturePetZip()),
      ),
      _failsWith('theme-pet-id'),
    );
    expect(
      () => ThemePackValidator.validateArchive(
        _themeZip(_themeJson(pet: const {'id': 'user-xmas-narwhal'}), pet: _fixturePetZip()),
      ),
      returnsNormally,
    );
  });

  test('a broken pet zip keeps the stable pet archive/pack codes', () {
    expect(
      () => ThemePackValidator.validateArchive(_themeZip(_themeJson(), pet: Uint8List.fromList([1, 2, 3, 4]))),
      _failsWith('theme-pet-archive'),
    );
    final noId = _zip({
      'pack.json': utf8.encode(jsonEncode({'schema': 1, 'name': '雪独角鲸'})),
      'idle.png': File('$_fixture/idle.png').readAsBytesSync(),
    });
    expect(() => ThemePackValidator.validateArchive(_themeZip(_themeJson(), pet: noId)), _failsWith('theme-pet-pack'));
  });

  test('a bundled pet is still held to the pet sheet cap', () {
    final big = Uint8List(petSheetByteCap + 1);
    final oversized = _petZip(
      json: _petPack(sheet: 'big.png'),
      sheets: {'big.png': big},
    );
    expect(
      () => ThemePackValidator.validateArchive(_themeZip(_themeJson(), pet: oversized)),
      _failsWith('theme-pet-too-large'),
    );
  });

  test('a bundled pet does not widen the theme archive; the art keeps its 32 MiB ceiling', () {
    // One archive reader (PetArchive) caps the theme zip at 64 MiB; the pet
    // member is validated by the pet rules inside that same envelope.
    expect(themePetMemberByteCap, petArchiveByteCap);
    expect(themeTotalAssetByteCap, 32 * 1024 * 1024);
    expect(themeImageByteCap, 8 * 1024 * 1024);
    expect(themeFontByteCap, 16 * 1024 * 1024);

    // Two full-size fonts (the most typography allows) plus one pixel of art
    // is over the asset budget even though a pet rides along.
    Uint8List font() => Uint8List(themeFontByteCap)
      ..[0] = 0x4F
      ..[1] = 0x54
      ..[2] = 0x54
      ..[3] = 0x4F;
    final assets = {'a.otf': font(), 'b.otf': font(), 'dot.png': File('$_fixture/preview.png').readAsBytesSync()};
    expect(
      () => ThemePackValidator.validateParts(
        _themeJson(font: 'a.otf', font2: 'b.otf', image: 'dot.png'),
        assets,
        petZip: _fixturePetZip(),
      ),
      _failsWith('theme-asset-total-size'),
    );
  });

  test('userPetIdFor already carries the prefix and is not doubled', () {
    expect(userPetIdFor('xmas-narwhal'), _petId);
    expect(userPetIdFor(_petId), _petId);
  });
}
