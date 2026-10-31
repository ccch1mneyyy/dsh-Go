/// Path rules for the native memory page.
///
/// The manifest comes from the host, but its `root` and every `path` are still
/// untrusted input: a malformed or hostile manifest must not be able to read
/// files outside the shared memory directory through `workspaceFiles/read`.
library;

/// Joins a manifest entry to the memory [root], rejecting absolute paths,
/// `..`/`.`/empty segments and Windows drive prefixes.
///
/// Returns null when either side is not a usable absolute root or when the
/// entry would resolve outside [root].
String? memoryEntryPath(String root, String relative) {
  final base = _normalizeRoot(root);
  if (base == null) return null;

  final rel = relative.replaceAll('\\', '/').trim();
  if (rel.isEmpty) return null;
  if (rel.startsWith('/')) return null;
  if (RegExp(r'^[A-Za-z]:').hasMatch(rel)) return null;

  final parts = rel.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return null;
  }
  return '$base/${parts.join('/')}';
}

/// Absolute directory with no `..` segments and no trailing slash. Null when
/// [root] is relative or otherwise unusable for containment checks.
String? _normalizeRoot(String root) {
  final raw = root.replaceAll('\\', '/').trim();
  if (raw.isEmpty) return null;
  final base = raw.replaceFirst(RegExp(r'/+$'), '');
  if (base.isEmpty) return null;

  final unix = base.startsWith('/');
  final windows = RegExp(r'^[A-Za-z]:/').hasMatch(base);
  if (!unix && !windows) return null;
  if (base.split('/').contains('..')) return null;
  return base;
}
