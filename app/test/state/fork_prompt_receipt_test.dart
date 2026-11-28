import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/fork_prompt_receipt.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

const _session = 'fork';
const _request = 'new-request';

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  late final events = StreamController<DshEvent>(onCancel: () {
    cancellations++;
  });
  int cancellations = 0;
  final watches = <(String, WatchOptions)>[];

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) {
    watches.add((sessionId, options));
    return events.stream;
  }
}

class _ActiveHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  @override
  void select(HostRef host) => state = host;
}

class _Harness {
  _Harness() {
    container = ProviderContainer(
      overrides: [activeHostProvider.overrideWith(_ActiveHost.new), _override(client)],
    );
    addTearDown(() async {
      container.dispose();
      if (client.watches.isNotEmpty) await client.events.close();
      await client.close();
    });
  }

  late final ProviderContainer container;
  final client = _Client();

  void replaceClient(DshClient next) {
    container.updateOverrides([activeHostProvider.overrideWith(_ActiveHost.new), _override(next)]);
    container.read(activeConnectionProvider);
  }

  Future<int?> wait() => waitForForkPrompt(container, sessionId: _session, requestId: _request, client: client);
}

Override _override(DshClient client) =>
    activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true)));

Map<String, Object?> _prompt(
  int seq, {
  String request = _request,
  String kind = 'user',
  bool withPrincipal = false,
}) => {
  'type': 'user/message',
  'seq': seq,
  'time': 1792700000000 + seq,
  'data': {
    'id': 'm$seq',
    'role': 'user',
    'content': <Object?>[],
    'source': {
      'kind': kind,
      'rpcId': request,
      if (withPrincipal) 'principal': {'kind': 'plugin'},
    },
  },
};

Map<String, Object?> _seedEnd(int seq) => {
  'type': 'session/end-seed',
  'seq': seq,
  'data': {'inherited': true},
};

SessionSnapshotEvent _snapshot(List<Map<String, Object?>> records, {String session = _session}) =>
    SessionSnapshotEvent.fromJson(session, {
      'cursor': records.isEmpty ? -1 : records.last['seq'],
      'records': [
        for (final event in records) {'event': event},
      ],
    });

void main() {
  test('recovers only the first own prompt after the latest seed boundary', () {
    final events = _snapshot([
      _seedEnd(1),
      _prompt(2),
      _seedEnd(9),
      _prompt(10, withPrincipal: true),
      _prompt(11, kind: 'schedule'),
      _prompt(12, request: 'first-own'),
      _prompt(13),
    ]).events;
    expect(firstOwnForkPrompt(events), 12);
  });

  test('does not recover a prompt when the boundary or contiguous tail is missing', () {
    expect(firstOwnForkPrompt(_snapshot([_prompt(3)]).events), isNull);
    expect(firstOwnForkPrompt(_snapshot([_prompt(3), _seedEnd(4)]).events), isNull);
    expect(firstOwnForkPrompt(_snapshot([_seedEnd(4), _prompt(6)]).events), isNull);
    expect(firstOwnForkPrompt(_snapshot([_seedEnd(4), _prompt(5), _prompt(7)]).events), isNull);
  });

  test('finds the durable request in a snapshot after the turn already ended', () async {
    final h = _Harness();
    final result = h.wait();
    h.client.events.add(
      _snapshot([
        _prompt(1, request: 'inherited'),
        _seedEnd(4),
        _prompt(5),
        {
          'type': 'turn/end',
          'seq': 6,
          'data': {
            'turn': 2,
            'reason': {'kind': 'aborted'},
          },
        },
      ]),
    );
    expect(await result, 5);
    expect(h.client.cancellations, 1);
    final (sessionId, options) = h.client.watches.single;
    expect(sessionId, _session);
    expect(options.activate, isFalse);
    expect(options.assistantStream, isFalse);
    expect(options.includeHostEvents, isFalse);
  });

  test('uses its exact receipt when the bounded snapshot has no seed marker', () async {
    final h = _Harness();
    final result = h.wait();
    h.client.events.add(_snapshot([_prompt(5, request: 'different-request'), _prompt(6)]));
    expect(await result, 6);
  });

  test('does not fall back to its request when a visible seed has a gap', () async {
    final h = _Harness();
    final result = h.wait();
    h.client.events.add(_snapshot([_seedEnd(4), _prompt(6)]));
    expect(await result, isNull);
  });

  for (final inSnapshot in [true, false]) {
    test('does not bind the second request (in snapshot: $inSnapshot)', () async {
      final h = _Harness();
      final result = h.wait();
      final events = h.client.events;
      final first = _prompt(5, request: 'different-request');
      final second = _prompt(6);
      events.add(_snapshot([_seedEnd(4), if (inSnapshot) ...[first, second]]));
      if (!inSnapshot) {
        events.add(SessionLogEvent.fromJson(first));
        events.add(SessionLogEvent.fromJson(second));
      }
      expect(await result, isNull);
      expect(h.client.cancellations, 1);
    });
  }

  test('waits for a fresh baseline and ignores other requests, injections and principals', () async {
    final h = _Harness();
    final result = h.wait();
    final events = h.client.events;
    events.add(_snapshot([_prompt(0)], session: 'other'));
    events.add(SessionLogEvent.fromJson(_prompt(1))); // No baseline for this fork yet.
    final stale = _snapshot([_prompt(1)]);
    events.add(stale.withEvents(stale.events, followEpoch: SessionFollowEpoch()..retire()));
    events.add(_snapshot([_prompt(2, request: 'same-content')]));
    events.add(SessionLogEvent.fromJson(_prompt(3, kind: 'schedule')));
    events.add(SessionLogEvent.fromJson(_prompt(4, withPrincipal: true)));
    events.add(SessionSyncEvent(SessionFollowEpoch()));
    events.add(SessionLogEvent.fromJson(_prompt(5))); // Gap recovery needs another snapshot.
    events.add(_snapshot([_prompt(6, request: 'later-request')]));
    events.add(SessionLogEvent.fromJson(_prompt(7)));
    expect(await result, 7);
    expect(h.client.cancellations, 1);
  });

  test('abandons the receipt when the selected host changes and returns', () async {
    final h = _Harness();
    final result = h.wait();
    h.client.events.add(_snapshot([_prompt(5)]));
    final host = h.container.read(activeHostProvider.notifier);
    host.select(const HostRef.ssh('other'));
    host.select(HostRef.local);
    expect(await result, isNull);
    expect(h.client.cancellations, 1);
  });

  test('abandons the old receipt when the connection client is replaced', () async {
    final h = _Harness();
    final replacement = _Client();
    addTearDown(replacement.close);
    final result = h.wait();
    h.replaceClient(replacement);
    expect(await result, isNull);
    expect(h.client.cancellations, 1);
    expect(replacement.watches, isEmpty);
    expect(await h.wait(), isNull);
    expect(h.client.watches, hasLength(1));
  });

  test('ends on a failed follow', () async {
    final h = _Harness();
    final result = h.wait();
    h.client.events.addError(const DshRemoteException('session/not-found', 'fork not found'));
    expect(await result, isNull);
    expect(h.client.cancellations, 1);
  });

  testWidgets('releases the passive follow after a bounded wait without an echo', (tester) async {
    final h = _Harness();
    final result = h.wait();
    h.client.events.add(_snapshot([]));
    await tester.pump(const Duration(seconds: 11));
    expect(await result, isNull);
    expect(h.client.watches, hasLength(1));
    expect(h.client.cancellations, 1);
  });
}
