// Strict validation for theme pack archives (theme.json + optional PNGs/fonts).
// Shares the ZIP structure, Unicode alias, strict UTF-8 JSON and PNG integrity
// gates with pet_pack_validator.dart and the Workshop Worker.

import 'dart:convert';
import 'dart:typed_data';

import '../pets/pet_ids.dart';
import '../pets/pet_name_alias.dart';
import '../pets/pet_pack_validator.dart';
import '../workshop/workshop_models.dart' show workshopLicenses;
import 'theme_pack.dart';

const themeJsonCap = 128 * 1024;
const themeImageByteCap = 8 * 1024 * 1024;
const themeFontByteCap = 16 * 1024 * 1024;
const themeTotalAssetByteCap = 32 * 1024 * 1024;
const themeImageSideCap = 4096;
const themeImageDecodedCap = 16 * 1024 * 1024;

/// The optional member a theme pack carries: a complete pet pack zip.
const themePetMemberName = 'pet.zip';

/// A bundled pet does not widen the theme archive: [PetArchive] still caps the
/// whole file and its expanded members at 64 MiB, the same limit a pet imported
/// on its own faces. Inside that envelope the artwork keeps its 32 MiB ceiling
/// ([themeTotalAssetByteCap]) and the pet keeps its own limits (64 MiB archive,
/// 48 MiB of sheets, 256 entries). So a pet plus artwork can never exceed the
/// existing 64 MiB, and each part is still checked by its own rules instead of
/// a single relaxed total. Raising the outer cap for themes would turn every
/// petless theme import into a larger memory/parse target for no benefit.
const themePetMemberByteCap = petArchiveByteCap;

class ThemeValidationException implements Exception {
  const ThemeValidationException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => 'ThemeValidationException($code${detail == null ? '' : ': $detail'})';
}

void _need(bool condition, String code, [String? detail]) {
  if (!condition) throw ThemeValidationException(code, detail);
}

/// A newer pack must say so, not fall into the generic malformed-schema error:
/// its fields are unknown to this app, and the person needs a newer app.
void _schemaVersionGate(Map<String, Object?> raw) {
  final schema = raw['schema'];
  if (schema is int && schema > themePackSchema) {
    throw ThemeValidationException('theme-schema-version', 'theme.json schema $schema is newer than $themePackSchema');
  }
}

bool isValidThemeFontBytes(Uint8List bytes) {
  if (bytes.length < 12 || bytes.length > themeFontByteCap) return false;
  if (bytes[0] == 0x00 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00) {
    return true;
  }
  final tag = String.fromCharCodes(bytes.sublist(0, 4));
  return tag == 'OTTO' || tag == 'true';
}

class ValidatedThemePack {
  const ValidatedThemePack({
    required this.json,
    required this.pack,
    required this.assets,
    this.petZip,
  });

  final Map<String, Object?> json;
  final ThemePack pack;
  final Map<String, Uint8List> assets;

  /// The validated `pet.zip` member, when the archive carried one. Absent from
  /// [validateParts] calls that only re-check an installed theme.
  final Uint8List? petZip;
}

class ThemePackValidator {
  ThemePackValidator._();

  static ValidatedThemePack validateArchive(
    Uint8List bytes, {
    bool market = false,
  }) {
    final PetArchive archive;
    try {
      archive = PetArchive.read(bytes);
    } on PetValidationException catch (error) {
      throw ThemeValidationException(error.code, error.path);
    }
    return validateThemeArchive(archive, market: market);
  }

  static ValidatedThemePack validateThemeArchive(
    PetArchive archive, {
    bool market = false,
  }) {
    final candidates = archive.manifestPaths('theme.json');
    _need(candidates.length == 1, 'archive-theme-count');
    final manifestPath = candidates.single;
    final prefix = manifestPath.substring(0, manifestPath.length - 'theme.json'.length);

    final Object? decoded;
    try {
      decoded = decodePetJson(archive.readFile(manifestPath, maxBytes: themeJsonCap));
    } on PetValidationException catch (error) {
      throw ThemeValidationException(error.code, error.path);
    }
    _need(decoded is Map<String, Object?>, 'theme-json-object');
    final raw = decoded as Map<String, Object?>;

    _schemaVersionGate(raw);
    final ThemePack pack;
    try {
      pack = ThemePack.parse(raw);
    } on FormatException catch (error) {
      throw ThemeValidationException('theme-schema', error.message);
    }

    final referenced = <String>{...pack.referencedImages, ...pack.referencedFonts};
    final aliases = <String>{};
    for (final asset in referenced) {
      final alias = petNameAlias(asset);
      _need(aliases.add(alias), 'theme-asset-alias', asset);
    }

    final assets = <String, Uint8List>{};
    var total = 0;
    for (final name in referenced) {
      final fullPath = '$prefix$name';
      _need(archive.fileNames.contains(fullPath), 'theme-asset-missing', name);
      final isImage = pack.referencedImages.contains(name);
      final cap = isImage ? themeImageByteCap : themeFontByteCap;
      final remaining = themeTotalAssetByteCap - total;
      final Uint8List data;
      try {
        data = archive.readFile(fullPath, maxBytes: cap < remaining ? cap : remaining);
      } on PetValidationException catch (error) {
        throw ThemeValidationException(
          error.code == 'archive-member-size' ? 'theme-asset-too-large' : error.code,
          name,
        );
      }
      total += data.length;
      assets[name] = data;
    }

    final petPath = '$prefix$themePetMemberName';
    final hasPet = archive.fileNames.contains(petPath);
    if (pack.pet != null) _need(hasPet, 'theme-pet-missing', themePetMemberName);
    Uint8List? petZip;
    if (hasPet) {
      try {
        petZip = archive.readFile(petPath, maxBytes: themePetMemberByteCap);
      } on PetValidationException catch (error) {
        throw ThemeValidationException(
          const {
            'archive-size',
            'archive-entries',
            'archive-expanded-size',
            'archive-member-size',
          }.contains(error.code)
              ? 'theme-pet-too-large'
              : 'theme-pet-archive',
          error.path ?? error.code,
        );
      }
    }
    return validateParts(raw, assets, market: market, petZip: petZip);
  }

  static ValidatedThemePack validateParts(
    Map<String, Object?> raw,
    Map<String, Uint8List> assets, {
    bool market = false,
    Uint8List? petZip,
  }) {
    _schemaVersionGate(raw);
    ThemePack pack;
    try {
      pack = ThemePack.parse(raw);
    } on FormatException catch (error) {
      throw ThemeValidationException('theme-schema', error.message);
    }

    // No member here means an installed (or studio-edited) pack that keeps its
    // link without holding the archive again; only a theme zip is checked
    // against the pet it carries.
    if (petZip != null) {
      _need(pack.pet != null, 'theme-pet-unexpected', themePetMemberName);
      final pet = _validatePet(petZip);
      final expected = userPetIdFor(pet.pack.id);
      _need(pack.pet!.id == expected, 'theme-pet-id', '${pack.pet!.id} != $expected');
      if (pack.pet!.name == null) pack = pack.copyWith(pet: pack.pet!.withName(pet.pack.name));
    }

    if (market) {
      _need(
        pack.author != null &&
            pack.license != null &&
            workshopLicenses.contains(pack.license) &&
            pack.source != null,
        'theme-metadata',
      );
    }

    final referencedImages = pack.referencedImages;
    final referencedFonts = pack.referencedFonts;
    final allReferenced = <String>{...referencedImages, ...referencedFonts};
    final aliases = <String>{};
    for (final name in allReferenced) {
      _need(aliases.add(petNameAlias(name)), 'theme-asset-alias', name);
    }

    final kept = <String, Uint8List>{};
    var total = 0;
    for (final name in referencedImages) {
      final bytes = assets[name];
      _need(bytes != null, 'theme-asset-missing', name);
      _need(bytes!.isNotEmpty && bytes.length <= themeImageByteCap, 'theme-asset-too-large', name);
      total += bytes.length;
      _need(total <= themeTotalAssetByteCap, 'theme-asset-total-size');
      final size = pngSize(bytes);
      _need(size != null, 'theme-png-header', name);
      final (w, h) = size!;
      _need(
        w >= 1 &&
            h >= 1 &&
            w <= themeImageSideCap &&
            h <= themeImageSideCap &&
            w * h * 4 <= themeImageDecodedCap,
        'theme-png-dimensions',
        name,
      );
      _need(pngIntact(bytes), 'theme-png-corrupt', name);
      kept[name] = bytes;
    }

    for (final name in referencedFonts) {
      final bytes = assets[name];
      _need(bytes != null, 'theme-asset-missing', name);
      _need(bytes!.isNotEmpty && bytes.length <= themeFontByteCap, 'theme-asset-too-large', name);
      total += bytes.length;
      _need(total <= themeTotalAssetByteCap, 'theme-asset-total-size');
      _need(isValidThemeFontBytes(bytes), 'theme-font-invalid', name);
      kept[name] = bytes;
    }

    final normalized = pack.toJson();
    _need(utf8.encode(jsonEncode(normalized)).length <= themeJsonCap, 'theme-size');
    return ValidatedThemePack(
      json: normalized,
      pack: pack,
      assets: Map.unmodifiable(kept),
      petZip: petZip,
    );
  }

  /// The pet rules decide what a pet is; this only translates their stable
  /// failures into the theme import's stable pet codes.
  static ValidatedPetPack _validatePet(Uint8List bytes) {
    try {
      return PetPackValidator.validateArchive(bytes);
    } on PetValidationException catch (error) {
      final code = error.code;
      final detail = error.path ?? code;
      if (const {
        'archive-size',
        'archive-entries',
        'archive-expanded-size',
        'archive-member-size',
        'pack-size',
        'pack-normalized-size',
        'sheet-size',
        'sheet-count',
        'sheet-total-size',
      }.contains(code)) {
        throw ThemeValidationException('theme-pet-too-large', detail);
      }
      if (code == 'sheet-missing' ||
          code == 'archive-member-missing' ||
          code.startsWith('sheet-') ||
          code.startsWith('png-') ||
          code.startsWith('codex-')) {
        throw ThemeValidationException('theme-pet-asset', detail);
      }
      if (code.startsWith('json-') ||
          code.startsWith('pack-') ||
          code.startsWith('metadata-') ||
          code.startsWith('market-') ||
          code == 'archive-pack-count') {
        throw ThemeValidationException('theme-pet-pack', detail);
      }
      throw ThemeValidationException('theme-pet-archive', detail);
    }
  }
}
