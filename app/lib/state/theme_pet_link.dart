// What a theme pack's bundled pet does to the chosen pet: select it when the
// theme is selected, remember what was showing, and put that back when the
// theme goes away — unless the person chose something else in the meantime.
//
// The link is remembered in SharedPreferences, so a restart while the theme is
// active still knows what to restore. A theme selecting never opens a pet when
// 「不显示」 is chosen: the settings row offers it instead.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pets/pet_library.dart';
import '../pets/pet_prefs.dart';
import '../pets/pet_state.dart' show noPetId;
import '../themes/theme_pack.dart';
import 'appearance_state.dart';

@immutable
class ThemePetLink {
  const ThemePetLink({required this.themeId, required this.petId, required this.previousPetId});

  /// The active theme whose bundled pet was chosen.
  final String themeId;

  /// The bundled pet that was chosen.
  final String petId;

  /// The pet that was showing before; [noPetId] for 「不显示」.
  final String previousPetId;

  Map<String, Object?> toJson() => {
    'themeId': themeId,
    'petId': petId,
    'previousPetId': previousPetId,
  };

  static ThemePetLink? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final themeId = raw['themeId'], petId = raw['petId'], previous = raw['previousPetId'];
    if (themeId is! String || petId is! String || previous is! String) return null;
    if (themeId.isEmpty || petId.isEmpty || previous.isEmpty) return null;
    return ThemePetLink(themeId: themeId, petId: petId, previousPetId: previous);
  }

  @override
  bool operator ==(Object other) =>
      other is ThemePetLink &&
      other.themeId == themeId &&
      other.petId == petId &&
      other.previousPetId == previousPetId;

  @override
  int get hashCode => Object.hash(themeId, petId, previousPetId);
}

class ThemePetLinkController extends Notifier<ThemePetLink?> {
  static const key = 'theme.pet.link';

  late Future<void> _loaded;
  Future<void> _queue = Future.value();

  @override
  ThemePetLink? build() {
    ref.listen(appearanceProvider.select((s) => s.themePackId), (_, next) {
      _enqueue(() => _leftTheme(next));
    });
    ref.listen(activeThemePackProvider, (_, next) {
      if (next != null) _enqueue(() => _enteredTheme(next));
    });
    ref.listen(petPrefsProvider.select((p) => p.packId), (_, next) {
      _enqueue(() => _petChanged(next));
    });
    _loaded = _load();
    return null;
  }

  /// Tests wait on this instead of guessing how many turns the listeners need.
  @visibleForTesting
  Future<void> get settled async {
    await _loaded;
    var seen = _queue;
    await seen;
    while (!identical(seen, _queue)) {
      seen = _queue;
      await seen;
    }
  }

  /// 「使用配套宠物」: an explicit pick, so it also brings a hidden pet back.
  void useBundledPet(ThemePack pack) => _enqueue(() => _useBundledPet(pack));

  void _enqueue(Future<void> Function() task) {
    final run = _queue.then((_) => task());
    _queue = run.then((_) {}, onError: (Object _) {});
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = ThemePetLink.fromJson(jsonDecode(prefs.getString(key) ?? 'null'));
    } catch (_) {
      // No preferences backend (tests): no link.
    }
  }

  Future<void> _persist(ThemePetLink? link) async {
    state = link;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (link == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, jsonEncode(link.toJson()));
      }
    } catch (_) {
      // Kept for this run only.
    }
  }

  /// The selected theme changed (or went away).
  Future<void> _leftTheme(String? selected) async {
    await _loaded;
    await ref.read(petPrefsProvider.notifier).ready;
    await _releaseStale(selected);
  }

  /// A theme became active: offer its bundled pet, unless 「不显示」 or the
  /// same pet is already chosen (then it is not ours to take away later).
  Future<void> _enteredTheme(ThemePack pack) async {
    await _loaded;
    await ref.read(petPrefsProvider.notifier).ready;
    final selected = ref.read(appearanceProvider).themePackId;
    if (selected != pack.id) return; // a stale load of the theme before it
    await _releaseStale(selected);
    final link = state;
    if (link != null && link.themeId == pack.id) {
      // The link survived a restart. If the pet is no longer the bundled one
      // the person changed it; that choice wins.
      if (ref.read(petPrefsProvider).packId != link.petId) await _persist(null);
      return;
    }
    final pet = pack.pet;
    if (pet == null) return;
    final current = ref.read(petPrefsProvider).packId;
    if (current == noPetId || current == pet.id) return;
    if (!await _installed(pet.id)) return;
    await _persist(ThemePetLink(themeId: pack.id, petId: pet.id, previousPetId: current));
    await ref.read(petPrefsProvider.notifier).replacePack(pet.id);
  }

  Future<void> _useBundledPet(ThemePack pack) async {
    await _loaded;
    await ref.read(petPrefsProvider.notifier).ready;
    final pet = pack.pet;
    if (pet == null || ref.read(appearanceProvider).themePackId != pack.id) return;
    if (ref.read(petPrefsProvider).packId == pet.id) return;
    if (!await _installed(pet.id)) return;
    final current = ref.read(petPrefsProvider).packId;
    await _persist(ThemePetLink(themeId: pack.id, petId: pet.id, previousPetId: current));
    await ref.read(petPrefsProvider.notifier).setPack(pet.id);
  }

  Future<void> _petChanged(String packId) async {
    await _loaded;
    await ref.read(petPrefsProvider.notifier).ready;
    final link = state;
    if (link == null || packId == link.petId) return;
    // The person chose another pet while the theme was active: it is theirs,
    // not the theme's, when the theme leaves.
    await _persist(null);
  }

  /// Leaving [link]'s theme while its bundled pet is still the chosen one puts
  /// the previous pet back; a different choice only forgets the link.
  Future<void> _releaseStale(String? selected) async {
    final link = state;
    if (link == null || selected == link.themeId) return;
    final prefs = ref.read(petPrefsProvider);
    if (prefs.packId != link.petId) {
      await _persist(null);
      return;
    }
    final restore = await _restorable(link.previousPetId);
    await _persist(null);
    await ref.read(petPrefsProvider.notifier).replacePack(restore);
  }

  Future<bool> _installed(String id) async {
    if (builtInPets.contains(id)) return true;
    if (!isUserPet(id)) return false;
    try {
      return await ref.read(petLibraryProvider).contains(id);
    } on Object {
      return false;
    }
  }

  Future<String> _restorable(String id) async {
    if (id == noPetId || builtInPets.contains(id)) return id;
    if (isUserPet(id) && await _installed(id)) return id;
    // The remembered pet was removed while the theme was active: the default
    // is better than an id with no pack to draw.
    return defaultPetId;
  }
}

final themePetLinkProvider = NotifierProvider<ThemePetLinkController, ThemePetLink?>(
  ThemePetLinkController.new,
);
