import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'support/session_sync_host.dart';

Map<String, Object?> _largeSnapshot() => {
  ...syncSnapshot(1),
  'cursor': 300,
  'records': [
    syncEvent('turn/start', 0, 11),
    for (var seq = 1; seq < 300; seq++) syncEvent('future/unknown', seq, 11),
    {
      'type': 'event',
      'event': {'type': 'user/message', 'seq': 300, 'time': 1792700000300, 'data': syncItem('new baseline')},
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('large snapshot publishes atomically before subsequent streaming deltas', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final h = await SyncHarness.start(initialSnapshot: false);
      final readyItems = <List<ChatItem>>[];
      final sub = h.container.listen(chatProvider('S'), (_, state) {
        if (state.controlReady) readyItems.add(state.items);
      });
      try {
        final follow = h.follows.single;
        follow.socket.item(follow.id, _largeSnapshot());
        follow.socket.item(follow.id, {
          'type': 'assistant-stream',
          'frame': {'type': 'start', 'attemptId': 'live', 'revision': 1, 'turn': 11, 'step': 1, 'startedAfterSeq': 300},
        });
        follow.socket.item(follow.id, {
          'type': 'assistant-stream',
          'frame': {
            'type': 'chunk',
            'attemptId': 'live',
            'revision': 2,
            'index': 0,
            'time': 1792700000301,
            'chunk': {'type': 'text-delta', 'index': 0, 'text': 'after baseline'},
          },
        });
        await waitSync(
          () => h.state.items.whereType<AssistantChatItem>().any((item) => item.text == 'after baseline'),
          'ordered stream after background snapshot',
        );
        expect(h.observedTurns, [11]);
        expect(readyItems, isNotEmpty);
        for (final items in readyItems) {
          expect(items.whereType<UserChatItem>().single.text, 'new baseline');
        }
      } finally {
        sub.close();
        await h.close();
      }
    }, RealSyncHttp());
  });

  test('paging during snapshot preparation cannot mutate or discard loaded history', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      late SyncHarness h;
      final pagingDuringPreparation = Completer<void>();
      h = await SyncHarness.start(
        initialSnapshot: false,
        observe: (event) {
          if (event is SessionSnapshotEvent && event.events.length >= 256) {
            scheduleMicrotask(() {
              h.chat.loadOlder().then(pagingDuringPreparation.complete, onError: pagingDuringPreparation.completeError);
            });
          }
        },
      );
      try {
        final first = h.follows.single;
        first.socket.item(first.id, {
          ...syncSnapshot(1),
          'cursor': 300,
          'hasMore': true,
          'records': [syncEvent('turn/start', 300, 1)],
        });
        await waitSync(() => h.state.controlReady, 'initial page baseline');
        h.host.handlers['session/page'] = (_) => {
          'ok': true,
          'value': {
            'records': [
              {
                'type': 'event',
                'event': {'type': 'user/message', 'seq': 1, 'time': 1792700000001, 'data': syncItem('older')},
              },
            ],
            'hasMore': true,
          },
        };
        await h.chat.loadOlder();
        expect(h.state.items.whereType<UserChatItem>().single.text, 'older');
        expect(h.methods, ['session/page']);
        h.client.mux.reconnect();
        await waitSync(() => h.follows.length == 2, 'resync follow');
        final replacement = h.follows.last;
        replacement.socket.item(replacement.id, {
          ...syncSnapshot(1),
          'cursor': 600,
          'records': [
            syncEvent('turn/start', 300, 1),
            for (var seq = 301; seq <= 600; seq++) syncEvent('future/unknown', seq, 1),
          ],
        });
        await pagingDuringPreparation.future;
        await waitSync(() => h.state.controlReady, 'resync baseline');
        expect(h.methods, ['session/page'], reason: 'syncing must not start a concurrent history request');
        expect(h.state.items.whereType<UserChatItem>().single.text, 'older');
        expect(h.chat.events.first.seq, 1);
      } finally {
        await h.close();
      }
    }, RealSyncHttp());
  });

  for (final replaceConnection in [false, true]) {
    test(
      'background snapshot cannot publish after ${replaceConnection ? 'connection' : 'follow'} replacement',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          late SyncHarness h;
          Future<bool>? recovery;
          DshClient? replacement;
          h = await SyncHarness.start(
            initialSnapshot: false,
            observe: (event) {
              if (event is SessionSnapshotEvent && event.events.length >= 256) {
                // map() delivers the original event synchronously to asyncMap;
                // this runs at its first await, while the candidate is pending.
                scheduleMicrotask(() {
                  if (replaceConnection) {
                    replacement = DshClient(h.client.connection);
                    h.container.updateOverrides([
                      activeConnectionProvider.overrideWithValue(
                        AsyncData(HostConnection(client: replacement!, label: 'replacement', isLocal: true)),
                      ),
                    ]);
                  } else {
                    recovery = h.chat.resync();
                  }
                });
              }
            },
          );
          final ready = <bool>[];
          final sub = h.container.listen(chatProvider('S'), (_, state) => ready.add(state.controlReady));
          try {
            final follow = h.follows.single;
            follow.socket.item(follow.id, _largeSnapshot());
            await waitSync(() => h.follows.length == 2, 'superseding follow');
            expect(ready, isNot(contains(true)));
            expect(h.observedTurns, isEmpty);
            h.follows.last.socket.item(h.follows.last.id, syncSnapshot(2));
            if (recovery != null) expect(await recovery!, isTrue);
            await waitSync(() => h.state.controlReady, 'replacement baseline');
            expect(h.observedTurns, [1, 2]);
            expect(h.state.items, isEmpty);
          } finally {
            sub.close();
            await replacement?.close();
            await h.close();
          }
        }, RealSyncHttp());
      },
    );
  }
}
