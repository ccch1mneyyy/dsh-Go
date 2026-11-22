// Installing a theme that carries a pet: the pet goes in first (so a theme is
// never left pointing at nothing), the theme keeps the link, and the pet's own
// archive is not copied into the theme folder. `inspect` is the no-write
// preflight the settings page asks before replacing an installed pet.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/themes/theme_library.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
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

Uint8List _petZip({String? name}) => _zip({
  'pack.json': utf8.encode(jsonEncode({..._fixtureJson(), 'name': ?name})),
  for (final entry in _fixtureSheets().entries) entry.key: entry.value,
});

Map<String, Object?> _themeJson({bool pet = true}) => {
  'schema': pet ? 2 : 1,
  'id': 'xmas',
  'name': '圣诞雪夜',
  if (pet) 'pet': {'id': _petId, 'name': '雪独角鲸'},
};

Uint8List _themeZip({bool pet = true}) => _zip({
  'theme.json': utf8.encode(jsonEncode(_themeJson(pet: pet))),
  if (pet) 'pet.zip': _petZip(),
});

class _FailingPets extends PetLibrary {
  _FailingPets(super.root);

  @override
  Future<({String id, bool replaced})> install(
    File zip, {
    WorkshopReceipt? workshop,
    bool replaceExisting = false,
  }) async => throw const PetImportException(PetImportProblem.storage);
}

void main() {
  late Directory temp;
  late PetLibrary pets;
  late ThemeLibrary themes;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('theme-pet-install');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    themes = ThemeLibrary(() async => Directory('${temp.path}/themes'), pets: pets);
  });

  File writeZip(String name, Uint8List bytes) {
    final file = File('${temp.path}/$name');
    file.writeAsBytesSync(bytes);
    return file;
  }

  test('inspect reads the theme and its pet without writing anything', () async {
    final preview = await themes.inspect(writeZip('theme.zip', _themeZip()));
    expect(preview.id, 'user-xmas');
    expect(preview.name, '圣诞雪夜');
    expect(preview.replaced, isFalse);
    expect(preview.petId, _petId);
    expect(preview.petName, '雪独角鲸');
    expect(Directory('${temp.path}/themes').existsSync(), isFalse);
    expect(Directory('${temp.path}/pets').existsSync(), isFalse);

    final installed = await themes.install(writeZip('again.zip', _themeZip()));
    expect(installed.petId, _petId);
    final again = await themes.inspect(writeZip('third.zip', _themeZip()));
    expect(again.replaced, isTrue);
  });

  test('installing puts the pet in first, links it, and keeps pet.zip out of the theme', () async {
    // An older copy of the same pet is on the phone: the theme's copy wins.
    await pets.install(writeZip('old-pet.zip', _petZip(name: '旧雪独角鲸')), replaceExisting: true);
    expect((await pets.load(_petId)).name, '旧雪独角鲸');

    final installed = await themes.install(writeZip('theme.zip', _themeZip()), replaceExisting: true);
    expect(installed.id, 'user-xmas');
    expect(installed.replaced, isFalse);
    expect(installed.petId, _petId);
    expect((await pets.load(_petId)).name, '雪独角鲸');

    final theme = await themes.load('user-xmas');
    expect(theme.pet?.id, _petId);
    expect(theme.pet?.name, '雪独角鲸');
    final folder = await themes.folder('user-xmas');
    expect(File('${folder.path}/theme.json').existsSync(), isTrue);
    expect(File('${folder.path}/pet.zip').existsSync(), isFalse);
    expect(File('${folder.path}/idle.png').existsSync(), isFalse, reason: 'the pet lives in the pet library');
  });

  test('a theme without a pet installs exactly as before', () async {
    final installed = await themes.install(writeZip('plain.zip', _themeZip(pet: false)));
    expect(installed.petId, isNull);
    expect((await themes.load('user-xmas')).pet, isNull);
    expect(Directory('${temp.path}/pets').existsSync(), isFalse);
  });

  test('exporting a pet theme leaves the pet and pet.zip out', () async {
    await themes.install(writeZip('theme.zip', _themeZip()));
    final out = File('${temp.path}/export.zip');
    await themes.exportZip('user-xmas', out);

    final decoded = ZipDecoder().decodeBytes(await out.readAsBytes());
    expect(decoded.files.map((f) => f.name), ['theme.json']);
    final json = jsonDecode(utf8.decode(decoded.files.single.content as List<int>)) as Map<String, Object?>;
    expect(json['schema'], 1, reason: 'the exported pack imports on older apps');
    expect(json.containsKey('pet'), isFalse);
    expect(decoded.files.any((f) => f.name == 'pet.zip'), isFalse);
    // And it installs as a plain theme on any phone.
    final plain = ThemeLibrary(() async => Directory('${temp.path}/reimport'), pets: pets);
    expect((await plain.install(out)).petId, isNull);
  });

  test('a pet that cannot be written leaves the theme uninstalled', () async {
    final broken = ThemeLibrary(
      () async => Directory('${temp.path}/other-themes'),
      pets: _FailingPets(() async => Directory('${temp.path}/other-pets')),
    );
    await expectLater(
      () => broken.install(writeZip('fail.zip', _themeZip())),
      throwsA(
        isA<ThemeImportException>()
            .having((e) => e.problem, 'problem', ThemeImportProblem.storage)
            .having((e) => e.detail, 'detail', 'theme-pet-storage'),
      ),
    );
    expect(Directory('${temp.path}/other-themes/user-xmas').existsSync(), isFalse);
    // The staging folder an interrupted install leaves is cleaned up too.
    final leftovers = Directory('${temp.path}/other-themes')
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('.staging-'));
    expect(leftovers, isEmpty);
  });
}
