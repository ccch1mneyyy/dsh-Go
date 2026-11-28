import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/reply_versions_state.dart';
import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart';

class _SwitchHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  void set(HostRef host) => state = host;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const local = HostRef.local;
  ProviderContainer start() {
    final container = ProviderContainer(overrides: [activeHostProvider.overrideWith(_SwitchHost.new)]);
    addTearDown(container.dispose);
    return container;
  }

  Future<void> fork(
    ReplyVersionsController versions,
    String parent,
    int parentSeq,
    String child, {
    int? childSeq,
    bool edited = false,
    HostRef host = local,
  }) => versions.recordFork(
    host,
    parentSessionId: parent,
    parentPromptSeq: parentSeq,
    childSessionId: child,
    childPromptSeq: childSeq,
    edited: edited,
  );

  Future<HostConnection> connect(FakeWorkspaceHost host) async {
    final connection = workspaceHost(host);
    addTearDown(connection.client.close);
    await connection.client.mux.start();
    return connection;
  }

  ProviderContainer open(HostConnection connection) {
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(connection)),
        readListIdentityProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> loadDrawer(ProviderContainer container) async {
    container.read(workspacesProvider);
    await container.read(workspacePrefsProvider.notifier).selection();
    await container.read(sessionsProvider.future);
    await container.read(drawerViewProvider.notifier).ready();
    await pumpEventQueue();
  }

  List<DrawerBlock> blocks(ProviderContainer container, {DrawerFilter filter = DrawerFilter.all}) {
    final scope = container.read(drawerScopeProvider)!;
    return drawerBlocks(
      sessions: scope.sessions,
      pinnedIds: container.read(workspacesProvider).pinnedSessionIds,
      view: container.read(drawerViewProvider),
      filter: filter,
      pending: const {},
      unread: const {},
      createdAt: const {},
      now: DateTime(2026, 11, 28),
      scoped: scope.scoped,
      versions: container.read(drawerReplyVersionsProvider),
    );
  }

  Iterable<String> rows(ProviderContainer c) => c.read(sessionsProvider).requireValue.map((s) => s.sessionId);

  test('the source and real resend seq anchor each turn independently', () async {
    final container = start();
    final versions = container.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    await fork(versions, 'b', 40, 'c', childSeq: 46);
    await fork(versions, 'c', 14, 'd', childSeq: 17);
    await fork(versions, 'b', 40, 'e', childSeq: 39, edited: true);

    final index = container.read(replyVersionsProvider).requireValue;
    const firstTurn = [
      (sessionId: 'a', promptSeq: 10),
      (sessionId: 'b', promptSeq: 14),
      (sessionId: 'd', promptSeq: 17),
    ];
    const secondTurn = [
      (sessionId: 'b', promptSeq: 40),
      (sessionId: 'c', promptSeq: 46),
      (sessionId: 'e', promptSeq: 39),
    ];
    final inherited = index.selectionFor('c', 14)!;
    expect(inherited.versions, firstTurn);
    expect(inherited.index, 1);
    expect(inherited.hasEdits, isFalse);
    expect(index.selectionFor('d', 17)?.index, 2);
    expect(index.selectionFor('c', 46)?.versions, secondTurn);
    expect(index.selectionFor('c', 46)?.index, 1);
    expect(index.selectionFor('c', 46)?.hasEdits, isTrue);
    expect(index.selectionFor('e', 39)?.index, 2);
    expect(index.selectionFor('a', 40), isNull);
    expect(index.selectionFor('d', 46), isNull);
    expect(index.sessionIdsFor('c'), {'a', 'b', 'c', 'd', 'e'});
  });

  test('a missing author is reachable from an inheriting branch without exposing missing sessions', () async {
    final container = start();
    final versions = container.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    await fork(versions, 'b', 40, 'c', childSeq: 46);
    await fork(versions, 'a', 10, 'd', childSeq: 17);

    final before = container.read(replyVersionsProvider).requireValue;
    final visible = before.selectionFor('a', 10, availableSessionIds: {'a', 'c'})!;
    expect(visible.versions, [(sessionId: 'a', promptSeq: 10), (sessionId: 'c', promptSeq: 14)]);
    expect(visible.index, 0);

    const afterRemoval = {'a', 'c', 'd'};
    final inherited = before.selectionFor('c', 14, availableSessionIds: afterRemoval)!;
    expect(inherited.index, 1);
    expect(inherited.versions.map((version) => version.sessionId), ['a', 'c', 'd']);
    expect(before.selectionFor('c', 46, availableSessionIds: afterRemoval), isNull);
  });

  test('an earlier arrow switches back to the most recently opened continuation of its version', () async {
    final container = start();
    final versions = container.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    await fork(versions, 'b', 40, 'c', childSeq: 46);
    await fork(versions, 'c', 70, 'pending');
    await versions.select(local, 'c');
    await versions.select(local, 'pending');
    await versions.select(local, 'a');
    final index = container.read(replyVersionsProvider).requireValue;
    final selected = index.selectionFor('a', 10)!;
    expect(selected.versions, [(sessionId: 'a', promptSeq: 10), (sessionId: 'c', promptSeq: 14)]);
    expect(selected.index, 0);
    expect(index.selectionFor('c', 14)?.index, 1);
    expect(index.selectionFor('a', 10, availableSessionIds: {'a', 'b'})?.versions.last.sessionId, 'b');
  });

  test('host keys isolate identical session ids and ignore relay display names', () async {
    final container = start();
    final hosts = container.read(activeHostProvider.notifier) as _SwitchHost;
    final versions = container.read(replyVersionsProvider.notifier);
    const ssh = HostRef.ssh('pc');
    const relay = HostRef.relay('pc', name: 'before');
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    hosts.set(ssh);
    final empty = await container.read(replyVersionsProvider.future);
    expect(empty.host, ssh);
    expect(empty.selectionFor('a', 10), isNull);
    await fork(versions, 'a', 10, 'r', childSeq: 14, host: relay);
    expect(container.read(replyVersionsProvider).requireValue.host, ssh);
    hosts.set(const HostRef.relay('pc', name: 'after'));
    final remote = await container.read(replyVersionsProvider.future);
    expect(remote.selectionFor('a', 10)?.versions.last.sessionId, 'r');
    hosts.set(local);
    final restored = await container.read(replyVersionsProvider.future);
    expect(restored.selectionFor('a', 10)?.versions.last.sessionId, 'b');
  });

  test('drawer represents one real row, waits for the first prompt and restores the last selection', () async {
    final host = FakeWorkspaceHost();
    final time = DateTime.utc(2026, 11, 27);
    host.seedSession('a', 'First', time);
    host.seedSession('ordinary', 'Independent', time.add(const Duration(seconds: 1)));
    host.seedSession('b', 'Edited', time.add(const Duration(seconds: 2)));
    final connection = await connect(host);
    final first = open(connection);
    final versions = first.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', edited: true);
    final waiting = first.read(replyVersionsProvider).requireValue;
    expect(waiting.needsPrompt('b'), isTrue);
    expect(waiting.selectionFor('a', 10), isNull);
    await loadDrawer(first);
    expect(rows(first), ['b', 'ordinary', 'a']);
    expect(drawerSelectableIds(blocks(first)), ['ordinary', 'a']);

    first.read(currentSessionProvider.notifier).select('b');
    await pumpEventQueue();
    expect(drawerSelectableIds(blocks(first)), ['ordinary', 'a']);
    await versions.bindChildPrompt(local, 'b', 14);
    await versions.bindChildPrompt(local, 'b', 15); // A later human turn cannot overwrite the binding.
    expect(drawerSelectableIds(blocks(first)), ['b', 'ordinary']);
    expect(rows(first), ['b', 'ordinary', 'a']);
    final search = buildSessionSearchView(
      const SessionSearchState(text: 'First'),
      sessions: first.read(sessionsProvider).requireValue,
    );
    expect(search.results.active.single.session.sessionId, 'a');
    expect(first.read(replyVersionsProvider).requireValue.needsPrompt('b'), isFalse);
    expect(first.read(replyVersionsProvider).requireValue.selectionFor('b', 14)?.hasEdits, isTrue);
    expect(first.read(replyVersionsProvider).requireValue.selectionFor('b', 15), isNull);
    expect(first.read(hostSessionsProvider).keys, unorderedEquals(['a', 'b', 'ordinary']));

    first.read(currentSessionProvider.notifier).select('a');
    await pumpEventQueue();
    expect(drawerSelectableIds(blocks(first)), ['ordinary', 'a']);
    final second = open(connection);
    await second.read(replyVersionsProvider.future);
    await loadDrawer(second);
    expect(drawerSelectableIds(blocks(second)), ['ordinary', 'a']);
    expect(rows(second), ['b', 'ordinary', 'a']);
    expect(second.read(hostSessionsProvider).keys, unorderedEquals(['a', 'b', 'ordinary']));
    expect(second.read(replyVersionsProvider).requireValue.selectionFor('b', 14)?.hasEdits, isTrue);
    second.read(currentSessionProvider);
    await pumpEventQueue();
    expect(second.read(currentSessionProvider), 'a');

    host.sessions.removeWhere((session) => session['sessionId'] == 'a');
    await second.read(sessionsProvider.notifier).refresh();
    expect(rows(second), ['b', 'ordinary']);
    expect(drawerSelectableIds(blocks(second)), ['b', 'ordinary']);
  });

  test('workspace and status filters keep eligible branches even when another branch was selected', () async {
    final host = FakeWorkspaceHost();
    final time = DateTime.utc(2026, 11, 27);
    host.seedSession('a', 'First', time, running: true);
    host.seedSession('b', 'Edited', time.add(const Duration(seconds: 1)));
    final original = host.seedWorkspace('/root/original', sessionIds: ['a']);
    final edited = host.seedWorkspace('/root/edited', sessionIds: ['b']);
    final container = open(await connect(host));
    final versions = container.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    await versions.select(local, 'b');
    await loadDrawer(container);

    expect(container.read(drawerScopeProvider)!.sessions.map((s) => s.sessionId), ['b', 'a']);
    expect(drawerSelectableIds(blocks(container)), ['b']);
    expect(drawerSelectableIds(blocks(container, filter: DrawerFilter.running)), ['a']);

    final prefs = container.read(workspacePrefsProvider.notifier);
    await prefs.select(original['workspaceId'] as String);
    expect(drawerSelectableIds(blocks(container)), ['a']);
    await prefs.select(edited['workspaceId'] as String);
    await versions.select(local, 'a');
    expect(drawerSelectableIds(blocks(container)), ['b']);
    expect(rows(container), ['b', 'a']);
  });

  test('the displayed branch inherits existing pin and folder assignments without changing its selection id', () async {
    final host = FakeWorkspaceHost()..pinned = ['a'];
    final time = DateTime.utc(2026, 11, 27);
    host.seedSession('a', 'First', time);
    host.seedSession('b', 'Edited', time.add(const Duration(seconds: 1)));
    host.seedSession('ordinary', 'Independent', time.add(const Duration(seconds: 2)));
    final container = open(await connect(host));
    final versions = container.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    await loadDrawer(container);

    await versions.select(local, 'a');
    expect(blocks(container).whereType<PinnedBlock>().single.items.single.sessionId, 'a');
    await versions.select(local, 'b');
    expect(blocks(container).whereType<PinnedBlock>().single.items.single.sessionId, 'b');

    final folderId = await container
        .read(drawerViewProvider.notifier)
        .createFolder('Work', sessionIds: ['a', 'ordinary']);
    final layout = blocks(container);
    final folder = layout.whereType<FolderBlock>().single;
    expect(folder.folder.id, folderId);
    expect(folder.folder.sessionIds, ['a', 'ordinary']);
    expect(folder.pinnedIds, {'b'});
    expect(layout.whereType<PinnedBlock>(), isEmpty);
    expect(drawerSelectableIds(layout), ['b', 'ordinary']);

    final organization = container.read(drawerOrganizationProvider);
    expect(organization.folderIdFor('b'), folderId);
    expect(organization.pinTargets('b'), ['a']);
    expect(organization.folderTargets('b'), ['a']);
  });
}
