// How a brought pet is named on disk. Kept free of Flutter so the theme pack
// validator can hold a theme.json `pet.id` to the same contract the pet
// library writes.

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// Ids of brought pets start with this; the built-in ones never do.
const userPetPrefix = 'user-';

bool isUserPet(String id) => id.startsWith(userPetPrefix);

/// A folder name as kept under `<app support>/pets`: lower-case letters and
/// digits in dash-joined runs.
final userPetIdPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// The id a pack is kept under, after [userPetPrefix]. An id that already is
/// a plain folder name is kept as it is (with the prefix, which a pack
/// exported from here already has), so the same pet brought again replaces
/// itself. Any other is made folder-safe and told apart by a short hash of
/// the whole id: 「小猫」 and 「小狗」, `my cat` and `My Cat` stay two pets.
String userPetIdFor(String packId) {
  final bare = packId.startsWith(userPetPrefix) ? packId.substring(userPetPrefix.length) : packId;
  if (bare.length <= 48 && userPetIdPattern.hasMatch(bare)) return '$userPetPrefix$bare';
  var slug = bare.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 32) slug = slug.substring(0, 32).replaceAll(RegExp(r'-+$'), '');
  final hash = sha256.convert(utf8.encode(packId)).toString().substring(0, 8);
  return '$userPetPrefix${slug.isEmpty ? 'pet' : slug}-$hash';
}
