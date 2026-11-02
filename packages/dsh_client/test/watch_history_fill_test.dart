import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const _fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 10)]);

Map<String, Object?> _event(int seq) => {
  'seq': seq,
  'type': 'test/history',
  'time': seq,
  'data': {'seq': seq},
};
Map<String, Object?> _frame(int seq) => {'type': 'event', 'event': _event(seq)};
Map<String, Object?> _snapshot(int cursor, Iterable<int> seqs) => {
  'type': 'snapshot',
  'header': {'id': 's', 'version': 4, 'createdAt': 0},
  'cursor': cursor,
  'records': [for (final seq in seqs) _frame(seq)],
  'hasMore': true,
  'projections': {'asOfSeq': cursor, 'values': <String, Object?>{}},
  'assistantStream': {'revision': 0},
};

HistoryPage _page(Iterable<int> seqs, {bool hasMore = true}) =>
    HistoryPage([for (final seq in seqs) SessionLogEvent.fromJson(_event(seq))], hasMore);

class _HistoryClient extends DshClient {
  _HistoryClient(super.connection) : super(muxOptions: _fastMux);

  late Future<HistoryPage> Function(int through, int before) readPage;
  final requests = <({int through, int before})>[];

  @override
  Future<HistoryPage> history(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
    TurnWindow? turnWindow,
  }) {
    expect(sessionId, 's');
    expect(maxMessages, 500);
    expect(turnWindow, isNull);
    requests.add((through: throughSeq, before: beforeSeq!));
    return readPage(throughSeq, beforeSeq);
  }
}

// Detect work on a retired response directly, without timing a large list.
class _ObservedEvents extends ListBase<SessionLogEvent> {
  final values = _page([2, 3]).events;
  int reads = 0;

  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  SessionLogEvent operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, SessionLogEvent value) => throw UnsupportedError('read only');
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for watch');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  late FakeDsh host;
  late _HistoryClient client;

  setUp(() async {
    host = await FakeDsh.start();
    final connection = DshConnection(host.baseUri);
    await connection.login(FakeDsh.token);
    client = _HistoryClient(connection);
    await client.mux.ready();
  });
  tearDown(() async {
    await client.close();
    await host.close();
  });

  for (final sync in [false, true]) {
    test('large reconnect repair preserves every record and page boundary (sync: $sync)', () async {
      const missing = 100000;
      const cursor = missing + 3;
      var opens = 0;
      host.onOpen = (socket, id, endpoint, payload) {
        expect(endpoint, 'session/follow');
        socket.item(id, ++opens == 1 ? _snapshot(0, [0]) : _snapshot(cursor, [missing + 1, missing + 2, cursor]));
      };
      client.readPage = (through, before) async {
        expect(through, cursor);
        // Include both previously delivered history and overlapping upper
        // boundaries: only [from, before) may enter the repaired snapshot.
        return _page([0, for (var seq = max(1, before - 500); seq <= min(cursor, before + 1); seq++) seq]);
      };
      final events = <DshEvent>[];
      final errors = <Object>[];
      final sub = client
          .watch('s', options: WatchOptions(includeSyncEvents: sync))
          .listen(events.add, onError: errors.add);
      addTearDown(sub.cancel);
      await _until(() => events.whereType<SessionSnapshotEvent>().length == 1);
      client.mux.reconnect();
      await _until(() => events.whereType<SessionSnapshotEvent>().length == 2);

      final repaired = events.whereType<SessionSnapshotEvent>().last;
      expect(repaired.isResync, isTrue);
      expect(repaired.events.map((e) => e.seq), orderedEquals([for (var seq = 1; seq <= cursor; seq++) seq]));
      expect(repaired.events.every((e) => e.data['seq'] == e.seq), isTrue);
      expect(client.requests.map((r) => r.before), [for (var before = missing + 1; before > 1; before -= 500) before]);
      expect(errors, isEmpty);
    });
  }

  test('live gap repair keeps page order and excludes duplicate live/boundary records', () async {
    host.onOpen = (socket, id, endpoint, payload) {
      socket.item(id, _snapshot(0, [0]));
      for (final seq in [7, 7, 8]) {
        socket.item(id, _frame(seq));
      }
    };
    client.readPage = (through, before) async {
      expect(through, 6);
      return before == 7 ? _page([4, 5, 6, 7, 8]) : _page([0, 1, 2, 3, 4], hasMore: false);
    };
    final events = <DshEvent>[];
    final sub = client.watch('s').listen(events.add);
    addTearDown(sub.cancel);
    await _until(() => events.whereType<SessionLogEvent>().any((e) => e.seq == 8));
    expect(events.whereType<SessionLogEvent>().map((e) => e.seq), [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(client.requests.map((r) => r.before), [7, 4]);
  });

  test('sync repair still rejects an internal hole before publishing a snapshot', () async {
    var opens = 0;
    host.onOpen = (socket, id, endpoint, payload) {
      opens++;
      socket.item(id, switch (opens) {
        1 => _snapshot(0, [0]),
        2 => _snapshot(5, [4, 5]),
        _ => _snapshot(5, [1, 2, 3, 4, 5]),
      });
    };
    client.readPage = (_, _) async => _page([1, 3], hasMore: false);
    final events = <DshEvent>[];
    final errors = <Object>[];
    final sub = client
        .watch('s', options: const WatchOptions(includeSyncEvents: true))
        .listen(events.add, onError: errors.add);
    addTearDown(sub.cancel);
    await _until(() => events.whereType<SessionSnapshotEvent>().length == 1);
    client.mux.reconnect();
    await _until(() => events.whereType<SessionSnapshotEvent>().length == 2);
    expect(opens, 3);
    expect(events.whereType<SessionSnapshotEvent>().last.events.map((e) => e.seq), [1, 2, 3, 4, 5]);
    expect(client.requests, hasLength(1));
    expect(errors, isEmpty);
  });

  for (final connectionEvents in [false, true]) {
    test(
      'retired generation does not scan or continue an outstanding page (connection events: $connectionEvents)',
      () async {
        var opens = 0;
        host.onOpen = (socket, id, endpoint, payload) {
          socket.item(id, ++opens == 1 ? _snapshot(0, [0]) : _snapshot(5, [4, 5]));
        };
        final pending = Completer<HistoryPage>();
        final stale = _ObservedEvents();
        client.readPage = (_, _) => client.requests.length == 1 ? pending.future : Future.value(_page([1, 2, 3]));
        final events = <DshEvent>[];
        final errors = <Object>[];
        final sub = client
            .watch('s', options: WatchOptions(includeConnectionEvents: connectionEvents, includeSyncEvents: true))
            .listen(events.add, onError: errors.add);
        addTearDown(sub.cancel);
        await _until(() => events.whereType<SessionSnapshotEvent>().length == 1);
        client.mux.reconnect();
        await _until(() => client.requests.length == 1);
        client.mux.reconnect();
        await _until(() => client.mux.generation?.number == 3);
        pending.complete(HistoryPage(stale, true));
        await _until(() => events.whereType<SessionSnapshotEvent>().length == 2);

        expect(stale.reads, 0);
        expect(client.requests.map((r) => r.before), [4, 4], reason: 'only the new follow may repair the gap');
        expect(opens, 3);
        final repaired = events.whereType<SessionSnapshotEvent>().last;
        expect(repaired.events.map((e) => e.seq), [1, 2, 3, 4, 5]);
        expect(repaired.followEpoch?.generation, same(client.mux.generation));
        expect(errors, isEmpty);
      },
    );
  }

  test('cancelled watch does not scan or fetch after an outstanding history response', () async {
    host.onOpen = (socket, id, endpoint, payload) {
      socket.item(id, _snapshot(0, [0]));
      socket.item(id, _frame(5));
    };
    final pending = Completer<HistoryPage>();
    final stale = _ObservedEvents();
    client.readPage = (_, _) => pending.future;
    final events = <DshEvent>[];
    final errors = <Object>[];
    final sub = client.watch('s').listen(events.add, onError: errors.add);
    await _until(() => client.requests.length == 1);
    await sub.cancel();
    pending.complete(HistoryPage(stale, true));
    // Completing the pending future queues _fill's continuation ahead of this
    // event-loop turn; assertions observe its cancellation check, not a timer race.
    await Future<void>.delayed(Duration.zero);
    expect(stale.reads, 0);
    expect(client.requests, hasLength(1));
    expect(events.whereType<SessionLogEvent>(), isEmpty);
    expect(errors, isEmpty);
  });
}
