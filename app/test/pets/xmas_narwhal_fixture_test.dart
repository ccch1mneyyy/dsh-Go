// The 雪独角鲸 / Snow Narwhal fixture pet pack (tool/make_xmas_narwhal.py):
// original 32x32 pixel art with a Santa hat baked into every frame. This reads
// the shipped fixture through the same validator the importer uses, then checks
// the parts the validator deliberately leaves to the author: sheet size, cell
// grid, two distinct frames per animation, the hat in every frame, the foot line,
// and that the four reactions are wired the way pet_stage.dart plays them.

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

/// `reactions` key -> animation name, exactly as pet_stage.dart asks for them.
const _reactions = {'tapLeft': 'react-left', 'tapRight': 'react-right', 'tickle': 'react-double', 'drag': 'react-drag'};

/// Reaction animation -> ms per frame (the manifest's per-frame duration).
const _reactionFrames = {'react-left': 220, 'react-right': 220, 'react-double': 240, 'react-drag': 260};

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

/// The lowest opaque row in one column of a 32x32 cell.
int _lowestOpaqueInColumn(List<int> rgba, int x) {
  var lowest = -1;
  for (var y = 0; y < 32; y++) {
    if (rgba[(y * 32 + x) * 4 + 3] != 0) lowest = y;
  }
  return lowest;
}

/// One cell flipped about the pack's `anchor.x` (16 px): column x <-> 31 - x.
List<int> _mirrorCell(List<int> rgba) {
  final mirrored = <int>[];
  for (var y = 0; y < 32; y++) {
    for (var x = 31; x >= 0; x--) {
      final i = (y * 32 + x) * 4;
      mirrored.addAll(rgba.sublist(i, i + 4));
    }
  }
  return mirrored;
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

  test('state animations are two 400 ms frames on a 32x32 full-canvas cell', () {
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

  test('reactions map taps, a tickle and a drag to one-shot two-frame animations', () {
    expect(pack.reactions, {
      for (final MapEntry(:key, :value) in _reactions.entries) key: [value],
    });
    expect(pack.reaction('drag')!.name, 'react-drag');
    for (final MapEntry(key: name, value: ms) in _reactionFrames.entries) {
      final animation = pack.animations[name]!;
      expect(animation.sheet, '$name.png', reason: name);
      expect(animation.cols, 2, reason: name);
      expect(animation.frameWidth, 32, reason: name);
      expect(animation.frameHeight, 32, reason: name);
      expect(animation.box, const Rect.fromLTWH(0, 0, 32, 32), reason: name);
      // A reaction plays once and the App returns to the state animation.
      expect(animation.loop, isFalse, reason: name);
      expect(animation.frames.map((f) => f.i), [0, 1], reason: name);
      expect(animation.frames.map((f) => f.ms), [ms, ms], reason: name);
      expect(animation.durationMs, ms * 2, reason: name);
      // The brief's band: two frames, 200-300 ms each (0.44-0.52 s per reaction).
      expect(ms, inInclusiveRange(200, 300), reason: name);
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

  test('the seven sheets are 64x32 and every cell is designed art', () {
    expect(validated.sheets.keys.toSet(), {
      'idle.png',
      'working.png',
      'thinking.png',
      'react-left.png',
      'react-right.png',
      'react-double.png',
      'react-drag.png',
    });
    const stateSheets = {'idle.png', 'working.png', 'thinking.png'};
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
        // No art crosses the foot line at row 28. State frames stand on it
        // (lowest art row 27); reactions may lift off it.
        final lowest = _lowestOpaqueRow(cell);
        expect(lowest, lessThanOrEqualTo(27), reason: '$reason stays above the foot line');
        if (stateSheets.contains(entry.key)) {
          expect(lowest, 27, reason: '$reason stands on the foot line');
        }
      }
      // Two frames, not a still: the head raises 1 px, the tail sways, or a
      // reaction leans/hops/hangs.
      var changed = 0;
      for (var i = 0; i < first.length; i++) {
        if (first[i] != second[i]) changed++;
      }
      expect(changed, greaterThan(100 * 4), reason: '${entry.key} frames differ');
    }
  });

  test('react-right is react-left mirrored about anchor.x', () {
    final left = image.decodePng(validated.sheets['react-left.png']!)!;
    final right = image.decodePng(validated.sheets['react-right.png']!)!;
    for (final index in [0, 1]) {
      expect(_cell(right, index), _mirrorCell(_cell(left, index)), reason: 'frame $index');
    }
  });

  test('the drag hangs 2 px up and the tickle hops 1 px', () {
    final idle = image.decodePng(validated.sheets['idle.png']!)!;
    final drag = image.decodePng(validated.sheets['react-drag.png']!)!;
    final tickle = image.decodePng(validated.sheets['react-double.png']!)!;
    // The mid-body column proves the whole body is held up: idle's outline is
    // on row 27, the drag's on row 25. The drooping fin still clears the foot
    // line, so the lowest art row stays at 26 or above.
    final idleFoot = _lowestOpaqueInColumn(_cell(idle, 0), 16);
    expect(idleFoot, 27);
    for (final index in [0, 1]) {
      final cell = _cell(drag, index);
      expect(_lowestOpaqueRow(cell), lessThan(27), reason: 'react-drag frame $index clears the foot line');
      expect(_lowestOpaqueInColumn(cell, 16), idleFoot - 2, reason: 'react-drag frame $index hangs 2 px up');
    }
    expect(_lowestOpaqueRow(_cell(tickle, 0)), 27);
    expect(_lowestOpaqueRow(_cell(tickle, 1)), 26);
  });
}
