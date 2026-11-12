// Public workspace state with committed Host mutations and delayed unary echoes.
import 'dart:async';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show FakeRuntime, FakeSettings;
import 'support.dart';

class _GatedPinHost extends FakeWorkspaceHost {
  _GatedPinHost({this.heldEndpoint = 'workspace/pinSession', this.emitPinFrames = true}) {
    for (final id in ['first', 'second', 'third']) {
      seedSession(id, id, DateTime.utc(2026, 11, 12));
    }
  }

  final String heldEndpoint;
  final bool emitPinFrames;
  final received = Completer<void>();
  final release = Completer<void>();
  bool _held = false;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final hold = !_held && endpoint == heldEndpoint;
    if (hold) _held = true;
    // Commit and capture the reply first, just as the Host command does.
    // Delay only the reply; later follow frames can arrive meanwhile.
    final result = await super.call(endpoint, args, timeout: timeout);
    if (hold) {
      received.complete();
      await release.future;
    }
    return result;
  }

  @override
  void push(Map<String, Object?> frame) {
    if (frame['type'] != 'pinned' || emitPinFrames) super.push(frame);
  }

  void sendPins(List<String> ids, {bool replace = false}) {
    pinned = List.of(ids);
    super.push(
      replace
          ? {
              'type': 'replace',
              'value': {'items': workspaces, 'archivedSessionIds': archived, 'pinnedSessionIds': pinned},
            }
          : {'type': 'pinned', 'pinnedSessionIds': pinned},
    );
  }
}

ProviderContainer _container(_GatedPinHost host) {
  final connection = workspaceHost(host);
  addTearDown(connection.client.close);
  final container = ProviderContainer(
    overrides: [
      activeConnectionProvider.overrideWithValue(AsyncData(connection)),
      localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true))),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(() {
    if (!host.release.isCompleted) host.release.complete();
  });
  container.listen(workspacesProvider, (_, _) {});
  return container;
}

Future<void> _when(ProviderContainer container, bool Function(WorkspacesState) matches) async {
  final done = Completer<void>();
  final sub = container.listen(workspacesProvider, (_, next) {
    if (!done.isCompleted && matches(next)) done.complete();
  }, fireImmediately: true);
  try {
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    sub.close();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('late unpin echo preserves a newer pushed pin set', () async {
    final host = _GatedPinHost(heldEndpoint: 'workspace/unpinSession')..pinned = ['first'];
    final container = _container(host);
    await _when(container, (state) => state.ready && listEquals(state.pinnedSessionIds, ['first']));
    final pending = container.read(workspacesProvider.notifier).unpinSession('first');
    await host.received.future;
    await _when(container, (state) => state.pinnedSessionIds.isEmpty);
    host.sendPins(['second']);
    await _when(container, (state) => listEquals(state.pinnedSessionIds, ['second']));
    host.release.complete();
    await pending;

    expect(container.read(workspacesProvider).pinnedSessionIds, ['second']);
    expect(host.argsOf('workspace/unpinSession'), [
      {
        'request': {'sessionId': 'first'},
      },
    ]);
  });

  test('overlapping pin echoes retain the latest request when replies reverse', () async {
    final host = _GatedPinHost(emitPinFrames: false);
    final container = _container(host);
    await _when(container, (state) => state.ready);
    final notifier = container.read(workspacesProvider.notifier);
    final first = notifier.pinSession('first');
    await host.received.future;
    await notifier.pinSession('second');
    expect(container.read(workspacesProvider).pinnedSessionIds, ['second', 'first']);
    host.release.complete();
    await first;

    expect(container.read(workspacesProvider).pinnedSessionIds, ['second', 'first']);
    expect(host.argsOf('workspace/pinSession'), [
      {
        'request': {'sessionId': 'first'},
      },
      {
        'request': {'sessionId': 'second'},
      },
    ]);
  });

  test('a full replace pin set supersedes an old pin echo', () async {
    final host = _GatedPinHost(emitPinFrames: false);
    final container = _container(host);
    await _when(container, (state) => state.ready);
    final pending = container.read(workspacesProvider.notifier).pinSession('first');
    await host.received.future;
    host.sendPins(['second'], replace: true);
    await _when(container, (state) => listEquals(state.pinnedSessionIds, ['second']));
    host.release.complete();
    await pending;

    expect(container.read(workspacesProvider).pinnedSessionIds, ['second']);
  });

  test('workspace and archive frames keep a valid pin or unpin unary reply', () async {
    final host = _GatedPinHost(emitPinFrames: false);
    final container = _container(host);
    await _when(container, (state) => state.ready);
    final notifier = container.read(workspacesProvider.notifier);
    final pending = notifier.pinSession('first');
    await host.received.future;
    final workspace = host.seedWorkspace('/root/other');
    host.push({'type': 'upsert', 'workspace': workspace});
    host.archived = ['third'];
    host.push({'type': 'archived', 'archivedSessionIds': host.archived});
    await _when(
      container,
      (state) =>
          state.byId(workspace['workspaceId']! as String) != null && listEquals(state.archivedSessionIds, ['third']),
    );
    host.release.complete();
    await pending;
    expect(container.read(workspacesProvider).pinnedSessionIds, ['first']);

    await notifier.unpinSession('first');
    final state = container.read(workspacesProvider);
    expect(state.pinnedSessionIds, isEmpty);
    expect(state.archivedSessionIds, ['third']);
    expect(state.byId(workspace['workspaceId']! as String)?.title, 'other');
  });
}
