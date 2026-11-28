import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hosts_state.dart';

/// A version's real session and the durable human prompt for that reply.
typedef ReplyVersion = ({String sessionId, int promptSeq});
typedef ReplyVersionSelection = ({List<ReplyVersion> versions, int index, bool hasEdits});

class _ReplyFork {
  const _ReplyFork(this.parent, this.childSessionId, this.childPromptSeq, this.edited);

  final ReplyVersion parent;
  final String childSessionId;
  final int? childPromptSeq;
  final bool edited;

  Map<String, Object?> toJson() => {
    'parentSessionId': parent.sessionId,
    'parentPromptSeq': parent.promptSeq,
    'childSessionId': childSessionId,
    'childPromptSeq': ?childPromptSeq,
    if (edited) 'edited': true,
  };
}

class ReplyVersionsState {
  ReplyVersionsState._(this.host, this._forks, this._recent);

  final HostRef host;
  final Map<String, _ReplyFork> _forks;
  final List<String> _recent; // Least to most recently selected.

  late final _roots = _buildRoots();
  late final _turns = _buildTurns();

  Map<String, String> _buildRoots() {
    final roots = <String, String>{};
    // Forks are kept in creation order; a child cannot be a parent first.
    for (final fork in _forks.values) {
      final parent = fork.parent.sessionId;
      roots[fork.childSessionId] = roots[parent] ??= parent;
    }
    return roots;
  }

  ({Map<ReplyVersion, List<ReplyVersion>> versions, Set<ReplyVersion> edited}) _buildTurns() {
    final versions = <ReplyVersion, List<ReplyVersion>>{};
    final edited = <ReplyVersion>{};
    for (final fork in _forks.values) {
      final root = _turnRoot(_authorOf(fork.parent));
      if (fork.edited) edited.add(root);
      final seq = fork.childPromptSeq;
      if (seq != null) (versions[root] ??= [root]).add((sessionId: fork.childSessionId, promptSeq: seq));
    }
    return (versions: versions, edited: edited);
  }

  // The Host copies the log prefix with the original seqs. A prompt before
  // the replaced one is inherited, except the child's own resend (whose seq
  // can differ due to fork markers, queue edits and turn/step events).
  ReplyVersion _authorOf(ReplyVersion prompt) {
    var author = prompt;
    while (true) {
      final fork = _forks[author.sessionId];
      if (fork == null) return author;
      final seq = author.promptSeq;
      final childSeq = fork.childPromptSeq;
      if (seq >= fork.parent.promptSeq || childSeq != null && seq >= childSeq) return author;
      author = (sessionId: fork.parent.sessionId, promptSeq: seq);
    }
  }

  ReplyVersion _turnRoot(ReplyVersion author) {
    var root = author;
    while (true) {
      final fork = _forks[root.sessionId];
      if (fork == null || fork.childPromptSeq != root.promptSeq) return root;
      root = _authorOf(fork.parent);
    }
  }

  /// Versions of exactly this turn, first answer first. For an inherited
  /// reply the active index is its authoring version, not the current session.
  ReplyVersionSelection? selectionFor(String sessionId, int promptSeq, {Set<String>? availableSessionIds}) {
    final author = _authorOf((sessionId: sessionId, promptSeq: promptSeq));
    final root = _turnRoot(author);
    final turn = _turns.versions[root];
    if (turn == null) return null;
    bool available(String id) => id == sessionId || availableSessionIds == null || availableSessionIds.contains(id);

    final choices = <ReplyVersion>[];
    var index = -1;
    for (final version in turn) {
      var target = _targetFor(version, available);
      if (version == author) {
        index = choices.length;
        target ??= (sessionId: sessionId, promptSeq: promptSeq);
      }
      if (target != null) choices.add(target);
    }
    if (index < 0 || choices.length < 2) return null;
    return (versions: List.unmodifiable(choices), index: index, hasEdits: _turns.edited.contains(root));
  }

  ReplyVersion? _targetFor(ReplyVersion author, bool Function(String) available) {
    final root = _roots[author.sessionId];
    ReplyVersion? inheriting(Iterable<String> ids) {
      for (final id in ids) {
        if (_roots[id] != root || !available(id) || needsPrompt(id)) continue;
        final candidate = (sessionId: id, promptSeq: author.promptSeq);
        if (_authorOf(candidate) == author) return candidate;
      }
      return null;
    }

    // Return to the extension of this exact reply the user last opened. If
    // its author has gone, a surviving prefix can still carry the version.
    return inheriting(_recent.reversed) ?? (available(author.sessionId) ? author : inheriting(_roots.keys));
  }

  /// The session is a newly opened version waiting for its first human input.
  bool needsPrompt(String sessionId) {
    final fork = _forks[sessionId];
    return fork != null && fork.childPromptSeq == null;
  }

  /// Stable identity of a reply-version group, not an action target.
  String drawerGroupId(String sessionId) => _roots[sessionId] ?? sessionId;

  /// Known real session ids in this drawer group (or just [sessionId] for an
  /// ordinary conversation). The host inventory determines availability.
  Set<String> sessionIdsFor(String sessionId) {
    final root = _roots[sessionId];
    if (root == null) return {sessionId};
    return {
      for (final entry in _roots.entries)
        if (entry.value == root) entry.key,
    };
  }

  /// [rows] are already newest first and eligible for this list. If the last
  /// selection isn't among them, keep an eligible version instead of hiding
  /// the whole group (e.g. a fork has not yet sent its prompt).
  List<SessionSummary> collapse(List<SessionSummary> rows) {
    if (_forks.isEmpty) return rows;
    final available = {for (final row in rows) row.sessionId};
    final representatives = <String, String>{};
    for (final id in _recent.reversed) {
      if (available.contains(id) && !needsPrompt(id)) {
        representatives.putIfAbsent(drawerGroupId(id), () => id);
      }
    }
    for (final row in rows) {
      final id = row.sessionId;
      if (!needsPrompt(id)) representatives.putIfAbsent(drawerGroupId(id), () => id);
    }
    return rows.where((row) {
      final id = row.sessionId;
      return representatives.putIfAbsent(drawerGroupId(id), () => id) == id;
    }).toList();
  }

  ReplyVersionsState _record(_ReplyFork fork) {
    if (_roots.containsKey(fork.childSessionId) || fork.parent.sessionId == fork.childSessionId) return this;
    return ReplyVersionsState._(host, {..._forks, fork.childSessionId: fork}, _recent);
  }

  ReplyVersionsState _bind(String childSessionId, int seq) {
    final fork = _forks[childSessionId];
    if (fork == null || fork.childPromptSeq != null) return this;
    return ReplyVersionsState._(
      host,
      {..._forks, childSessionId: _ReplyFork(fork.parent, childSessionId, seq, fork.edited)},
      _recent,
    );
  }

  ReplyVersionsState _select(String sessionId) {
    if (!_roots.containsKey(sessionId) || _recent.lastOrNull == sessionId) return this;
    return ReplyVersionsState._(host, _forks, [..._recent.where((id) => id != sessionId), sessionId]);
  }

  Map<String, Object?> _toJson() => {
    'forks': [for (final fork in _forks.values) fork.toJson()],
    'recent': _recent,
  };

  static ReplyVersionsState _fromJson(HostRef host, Object? raw) {
    final forks = <String, _ReplyFork>{};
    final ids = <String>{};
    final entries = raw is Map ? raw['forks'] : null;
    if (entries is List) {
      for (final entry in entries) {
        if (entry is! Map) continue;
        if (entry case {
          'parentSessionId': final String parent,
          'parentPromptSeq': final int seq,
          'childSessionId': final String child,
        } when parent.isNotEmpty && child.isNotEmpty && parent != child && !ids.contains(child)) {
          final childSeq = entry['childPromptSeq'];
          forks[child] = _ReplyFork(
            (sessionId: parent, promptSeq: seq),
            child,
            childSeq is int ? childSeq : null,
            entry['edited'] == true,
          );
          ids.addAll([parent, child]);
        }
      }
    }
    final recent = raw is Map ? raw['recent'] : null;
    return ReplyVersionsState._(
      host,
      forks,
      recent is List ? recent.whereType<String>().where(ids.contains).toList() : const [],
    );
  }
}

class ReplyVersionsController extends AsyncNotifier<ReplyVersionsState> {
  // Each host's load and mutations share a chain: a late read/write can't
  // undo a newer choice, even when the user switches away and back.
  final _byHost = <HostRef, Future<ReplyVersionsState>>{};
  late HostRef _host;

  static String keyFor(HostRef host) => 'reply.versions.${host.kind.name}.${host.id}';

  @override
  Future<ReplyVersionsState> build() => _forHost(_host = ref.watch(activeHostProvider));

  Future<ReplyVersionsState> _forHost(HostRef host) => _byHost.putIfAbsent(host, () => _load(host));

  Future<ReplyVersionsState> _load(HostRef host) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(keyFor(host));
      if (raw != null) return ReplyVersionsState._fromJson(host, jsonDecode(raw));
    } catch (error) {
      debugPrint('Reply version index could not be read: ${error.runtimeType}');
    }
    return ReplyVersionsState._(host, const {}, const []);
  }

  Future<void> _update(HostRef host, ReplyVersionsState Function(ReplyVersionsState) change) async {
    final owner = ref;
    final next = _forHost(host).then((current) async {
      final updated = change(current);
      if (identical(current, updated)) return current;
      try {
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setString(keyFor(host), jsonEncode(updated._toJson()))) {
          debugPrint('Reply version index could not be saved');
        }
      } catch (error) {
        debugPrint('Reply version index could not be saved: ${error.runtimeType}');
      }
      if (owner.mounted && _host == host) state = AsyncData(updated);
      return updated;
    });
    _byHost[host] = next;
    await next;
  }

  /// Records an edit or regenerate, not a manual fork of a finished turn.
  Future<void> recordFork(
    HostRef host, {
    required String parentSessionId,
    required int parentPromptSeq,
    required String childSessionId,
    int? childPromptSeq,
    bool edited = false,
  }) => _update(
    host,
    (index) => index._record(
      _ReplyFork((sessionId: parentSessionId, promptSeq: parentPromptSeq), childSessionId, childPromptSeq, edited),
    ),
  );

  /// The child's first durable resent human prompt is authoritative.
  Future<void> bindChildPrompt(HostRef host, String childSessionId, int childPromptSeq) =>
      _update(host, (index) => index._bind(childSessionId, childPromptSeq));

  Future<void> select(HostRef host, String sessionId) => _update(host, (index) => index._select(sessionId));
}

final replyVersionsProvider = AsyncNotifierProvider<ReplyVersionsController, ReplyVersionsState>(
  ReplyVersionsController.new,
);
