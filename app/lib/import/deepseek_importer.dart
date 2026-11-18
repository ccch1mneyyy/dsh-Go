// Turning a DeepSeek App export into host sessions.
//
// One conversation becomes one real session on the connected host: the app's
// own list, its own title, its own place in the drawer — the thing that makes
// "导入后接着聊" true rather than a viewer. What happened on the phone is kept
// beside it (deepseek_import/) and carried into the model on the first message
// from here (ImportedChatsController.takePreamble).
//
// Speed is the point here: an export of a few hundred conversations must not
// take minutes. So the controller's convenience wrappers are not used (create()
// asks the host for a workspace and re-reads the whole session list on every
// call, rename() re-reads it again), the host calls go out several at a time,
// and the store is written in chunks instead of once per conversation.

import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/connection_state.dart';
import '../state/sessions_state.dart';
import '../state/workspaces_state.dart';
import 'deepseek_export.dart';
import 'imported_chats.dart';

/// What an import did.
class DeepSeekImportOutcome {
  const DeepSeekImportOutcome({
    required this.imported,
    required this.skipped,
    required this.failed,
    required this.messages,
    required this.problems,
    required this.cancelled,
  });

  final int imported;

  /// Already here from an earlier import of the same file.
  final int skipped;
  final int failed;
  final int messages;
  final List<String> problems;
  final bool cancelled;

  bool get isEmpty => imported == 0;
}

/// Parses [zipPath] off the UI isolate.
Future<DeepSeekExport> readDeepSeekExport(String zipPath) =>
    Isolate.run(() => DeepSeekExport.readFromPath(zipPath));

/// Creates one session per conversation in [export].
///
/// [onProgress] is called as conversations finish with how many are done and how
/// many there are in total; [isCancelled] is asked before each one so the page
/// can stop a five-hundred-session import.
Future<DeepSeekImportOutcome> runDeepSeekImport({
  required WidgetRef ref,
  required DeepSeekExport export,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
  int concurrency = 12,
}) async {
  final conn = ref.read(activeConnectionProvider).value;
  if (conn == null) throw StateError('not connected');
  final store = ref.read(importedChatsProvider.notifier);
  final client = conn.client;

  final known = await store.alreadyImported();
  final conversations = <DeepSeekChat>[];
  final seenChats = <DeepSeekChat>[];
  var skipped = 0;
  for (final chat in export.conversations) {
    final seen = chat.id.isNotEmpty ? known.ids.contains(chat.id) : known.titles.contains(chat.sessionTitle);
    if (seen || known.titles.contains(chat.sessionTitle)) {
      skipped++;
      seenChats.add(chat);
      continue;
    }
    conversations.add(chat);
  }
  // 之前导入过的,用这次导出里的时间补齐索引:再导一次同一个包就能把
  // 「创建时间」从导入那一刻改成 DeepSeek 里的真实时间。
  if (seenChats.isNotEmpty) await store.refreshFromExport(seenChats);

  final total = conversations.length;
  final problems = <String>[];
  var created = 0;
  var messages = 0;
  var done = 0;
  var cancelled = false;

  if (total == 0) {
    return DeepSeekImportOutcome(
      imported: 0,
      skipped: skipped,
      failed: 0,
      messages: 0,
      problems: const [],
      cancelled: false,
    );
  }

  // One workspace for the whole import: the drawer's, else the host's own
  // directory (asking per conversation is one round trip each). The same test as
  // workspaceForNewSession, which wants a Ref rather than the page's WidgetRef.
  final selected = await ref.read(workspacePrefsProvider.notifier).selection();
  final registry = ref.read(workspacesProvider);
  final workspaceId = selected == null
      ? null
      : (registry.ready ? registry.byId(selected)?.workspaceId : selected);
  final cwd = conn.isLocal ? localWorkspaceDir : conn.workingDirectory;

  // recordAll writes the whole index, so chunks are written one at a time even
  // though the host calls run in parallel.
  final pending = <ImportedChatDraft>[];
  var flushQueue = Future<void>.value();
  Future<void> flush() {
    if (pending.isEmpty) return flushQueue;
    final chunk = List<ImportedChatDraft>.of(pending);
    pending.clear();
    final next = flushQueue.then((_) => store.recordAll(chunk));
    flushQueue = next.catchError((Object _) {});
    return next;
  }

  var cursor = 0;
  Future<void> worker() async {
    while (true) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        return;
      }
      final index = cursor++;
      if (index >= conversations.length) return;
      final chat = conversations[index];
      try {
        final session = await createSessionInWorkspace(client, workspaceId, cwd: cwd);
        await client.renameSession(session.sessionId, chat.sessionTitle);
        pending.add(ImportedChatDraft(
          sessionId: session.sessionId,
          title: chat.sessionTitle,
          messages: chat.messages,
          sourceId: chat.id.isEmpty ? null : chat.id,
          account: export.account,
          sourceCreatedAt: chat.createdAt,
          sourceUpdatedAt: chat.updatedAt,
        ));
        created++;
        messages += chat.messages.length;
        if (pending.length >= 40) await flush();
      } on Object catch (error) {
        problems.add('${chat.sessionTitle}: $error');
      }
      done++;
      onProgress?.call(done, total);
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  await flush();
  await flushQueue;

  // The drawer reads the list from the host: one read for the whole import,
  // after the rows exist, instead of one after each conversation.
  if (created > 0) {
    try {
      await ref.read(sessionsProvider.notifier).refresh();
    } on Object {
      // The rows land with the next list the drawer reads anyway.
    }
  }

  return DeepSeekImportOutcome(
    imported: created,
    skipped: skipped,
    failed: problems.length,
    messages: messages,
    problems: problems,
    cancelled: cancelled,
  );
}
