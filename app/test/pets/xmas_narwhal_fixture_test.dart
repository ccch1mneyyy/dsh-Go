// The 雪独角鲸 / Snow Narwhal fixture pet pack (tool/make_xmas_narwhal.py):
// original 32x32 pixel art with a Santa hat baked into every frame. This reads
// the shipped fixture through the same validator the importer uses, then checks
// the parts the validator deliberately leaves to the author: sheet size, cell
// grid, two distinct frames per state, the hat in every frame, and the foot line.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/pets/pet_pack_validator.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

const _fixture = 'test/fixtures/pets/xmas-narwhal';

Map<String, Object?> _packJson() => jsonDecode(File('$_fixture/pack.json').readAsStringSync()) as Map<String, Object?>;

/// The sheets named by the manifest, keyed by file name (the zip layout).
Map<String, Uint8List> _sheets(Map<String, Object?> json) {
  final animations = json['animations'] as Map<String, Object?>;
  final names = {for (final animation in animations.values) (animation as Map)['sheet'] as String};
  return {for (final name in names) name: File('$_fixture/$name').readAsBytesSync()};
}

Uint8List _zip(Map<String, Object?> json) {
  final archive = Archive();
  for (final entry in _sheets(json).entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  archive.add(ArchiveFile.bytes('pack.json', utf8.encode(jsonEncode(json))));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// The RGBA pixels of cell [index] of a 64x32 two-cell sheet.
List<int> _cell(image.Image sheet, int index) {
  final pixels = <int>[];
  for (var y = 0; y < sheet.height; y++) {
    for (var x = index * 32; x < index * 32 + 32; x++) {
      final p = sheet.getPixel(x, y);
      pixels.addAll([p.r.toInt(), p.g.toInt(), p.b.toInt(), p.a.toInt()]);
    }
  }
  return pixels;
}

int _opaque(List<int> rgba) => [
  for (var i = 3; i < rgba.length; i += 4)
    if (rgba[i] != 0) i,
].length;

int _red(List<int> rgba) {
  var count = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] != 0 && rgba[i] > 150 && rgba[i + 1] < 90 && rgba[i + 2] < 90) count++;
  }
  return count;
}

int _white(List<int> rgba) {
  var count = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] != 0 && rgba[i] > 248 && rgba[i + 1] > 248 && rgba[i + 2] > 248) count++;
  }
  return count;
}

/// The lowest opaque row inside one 32x32 cell.
int _lowestOpaqueRow(List<int> rgba) {
  var lowest = -1;
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 32; x++) {
      if (rgba[(y * 32 + x) * 4 + 3] != 0) lowest = y;
    }
  }
  return lowest;
}

void main() {
  final json = _packJson();
  final sheets = _sheets(json);
  final validated = PetPackValidator.validateParts(json, sheets);
  final pack = validated.pack;

  test('imports through the archive path with pack.json and sheets at the root', () {
    final result = PetPackValidator.validateArchive(_zip(json));
    expect(result.pack.id, 'xmas-narwhal');
    expect(result.dropped, isEmpty);
  });

  test('identity, canvas and body box', () {
    expect(pack.id, 'xmas-narwhal');
    expect(pack.name, '雪独角鲸');
    expect(pack.author, 'dsh-Go');
    expect(pack.license, 'CC0-1.0');
    expect(pack.source, 'original pixel art generated for dsh-Go');
    expect(pack.pixelArt, isTrue);
    expect(pack.scale, 1);
    expect(pack.canvas, const Size(32, 32));
    expect(pack.anchorX, 16);
    expect(pack.baseline, 28);
    expect(pack.contentBox, const Rect.fromLTWH(6, 10, 20, 14));
  });

  test('three animations, each two 400 ms frames on a 32x32 full-canvas cell', () {
    expect(pack.animations.keys, ['idle', 'working', 'thinking']);
    for (final name in ['idle', 'working', 'thinking']) {
      final animation = pack.animations[name]!;
      expect(animation.sheet, '$name.png', reason: name);
      expect(animation.cols, 2, reason: name);
      expect(animation.frameWidth, 32, reason: name);
      expect(animation.frameHeight, 32, reason: name);
      // frameW = trunc(box.w * scale) is what PetPackValidator enforces, so the
      // cell is the whole 32x32 canvas; contentBox stays the smaller body box.
      expect(animation.box, const Rect.fromLTWH(0, 0, 32, 32), reason: name);
      expect(animation.frameWidth, (animation.box.width * pack.scale).truncate(), reason: name);
      expect(animation.frameHeight, (animation.box.height * pack.scale).truncate(), reason: name);
      expect(animation.loop, isTrue, reason: name);
      expect(animation.frames.map((f) => f.i), [0, 1], reason: name);
      expect(animation.frames.map((f) => f.ms), [400, 400], reason: name);
      expect(animation.durationMs, 800, reason: name);
      expect(animation.sourceRect(0), const Rect.fromLTWH(0, 0, 32, 32), reason: name);
      expect(animation.sourceRect(1), const Rect.fromLTWH(32, 0, 32, 32), reason: name);
    }
  });

  test('states map idle / working / thinking to their animations', () {
    expect(pack.states, {
      'idle': ['idle'],
      'working': ['working'],
      'thinking': ['thinking'],
    });
    expect(pack.animFor(PetStateName.idle).name, 'idle');
    expect(pack.animFor(PetStateName.working).name, 'working');
    expect(pack.animFor(PetStateName.thinking).name, 'thinking');
    // Everything else falls back to idle, as the docs promise.
    expect(pack.animFor(PetStateName.sweeping).name, 'idle');
  });

  test('the three sheets are 64x32 and every cell is designed art', () {
    expect(validated.sheets.keys.toSet(), {'idle.png', 'working.png', 'thinking.png'});
    for (final entry in validated.sheets.entries) {
      final sheet = image.decodePng(entry.value);
      expect(sheet, isNotNull, reason: entry.key);
      expect(sheet!.width, 64, reason: entry.key);
      expect(sheet.height, 32, reason: entry.key);
      final first = _cell(sheet, 0);
      final second = _cell(sheet, 1);
      for (final (index, cell) in [first, second].indexed) {
        final reason = '${entry.key} frame $index';
        expect(_opaque(cell), greaterThan(150), reason: reason);
        // The Santa hat is baked into every frame (red cone + white trim).
        expect(_red(cell), greaterThan(8), reason: reason);
        expect(_white(cell), greaterThan(8), reason: reason);
        // The body stands on the baseline: lowest art row is 27, foot line 28.
        expect(_lowestOpaqueRow(cell), 27, reason: reason);
      }
      // Two frames, not a still: the head raises 1 px and the tail sways.
      var changed = 0;
      for (var i = 0; i < first.length; i++) {
        if (first[i] != second[i]) changed++;
      }
      expect(changed, greaterThan(100 * 4), reason: '${entry.key} frames differ');
    }
  });
}
