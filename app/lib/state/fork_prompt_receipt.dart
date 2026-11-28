import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'hosts_state.dart';

const _receiptTimeout = Duration(seconds: 10);
const _seedBoundary = 'session/end-seed';

bool _isOwnPrompt(UserMessageEvent event) =>
    event.seq >= 0 &&
    event.message.role == MessageRole.user &&
    event.isHumanPrompt &&
    !event.message.source.raw.containsKey('principal');

/// The first own human prompt after the latest fork boundary, if the loaded
/// events (in seq order) cover that boundary continuously through the tail.
int? firstOwnForkPrompt(Iterable<SessionLogEvent> events) => _forkPromptTail(events).first?.seq;

({bool sawBoundary, int? throughSeq, UserMessageEvent? first}) _forkPromptTail(Iterable<SessionLogEvent> events) {
  var sawBoundary = false;
  var continuous = false;
  var ordered = true;
  int? previous;
  UserMessageEvent? first;
  for (final event in events) {
    if (previous != null && event.seq <= previous) ordered = false;
    if (event.type == _seedBoundary) {
      // Forks copy older boundaries too. Only the latest marker counts.
      sawBoundary = true;
      continuous = event.seq >= 0;
      first = null;
    } else if (continuous) {
      continuous = event.seq == previous! + 1;
      if (first == null && event is UserMessageEvent && _isOwnPrompt(event)) first = event;
    }
    previous = event.seq;
  }
  final covered = continuous && ordered;
  return (sawBoundary: sawBoundary, throughSeq: covered ? previous : null, first: covered ? first : null);
}

/// Finds the durable prompt of a newly sent fork, after the send is acknowledged.
/// This is only a receipt for local version binding, not for the turn's reply.
Future<int?> waitForForkPrompt(
  ProviderContainer container, {
  required String sessionId,
  required String requestId,
  required DshClient client,
}) async {
  final receipt = Completer<int?>();
  var retired = false;
  void finish(int? seq) {
    if (!receipt.isCompleted) receipt.complete(seq);
  }

  void retire() {
    retired = true;
    finish(null);
  }

  bool owns(AsyncValue<HostConnection?> connection) =>
      !connection.isLoading && !connection.hasError && identical(connection.value?.client, client);

  ProviderSubscription<HostRef>? hostChanges;
  ProviderSubscription<AsyncValue<HostConnection?>>? clientChanges;
  try {
    final host = container.read(activeHostProvider);
    final hosts = hostChanges = container.listen(activeHostProvider, (_, next) {
      if (next != host) retire();
    });
    final connections = clientChanges = container.listen(activeConnectionProvider, (_, next) {
      if (!owns(next)) retire();
    }, fireImmediately: true);
    if (retired) return null;

    var ready = false;
    var sawBoundary = false;
    SessionFollowEpoch? epoch;
    bool currentEpoch() {
      final active = epoch;
      return active == null || (active.isCurrent && identical(active.generation, client.mux.generation));
    }

    void observePrompt(UserMessageEvent prompt) {
      if (prompt.requestId == requestId) {
        finish(prompt.seq);
      } else if (sawBoundary) {
        // The first prompt belongs to a different request. A later one is not
        // this version's source, even if its receipt would otherwise match.
        finish(null);
      }
    }

    // A passive follow avoids keeping a ChatController, token deltas or
    // approval listeners alive just for this one receipt. The initial snapshot
    // also covers a prompt that committed before its send ACK returned.
    final follow = client
        .watch(
          sessionId,
          options: const WatchOptions(
            assistantStream: false,
            includeHostEvents: false,
            includeSyncEvents: true,
            // A turn-only snapshot would start after the fork boundary.
            turnWindow: TurnWindow(1, 3),
          ),
        )
        .listen(
          (event) {
            if (receipt.isCompleted) return;
            switch (event) {
              case SessionSyncEvent():
                ready = false;
              case SessionSnapshotEvent(sessionId: final id, :final cursor, :final events, :final followEpoch)
                  when id == sessionId:
                epoch = followEpoch;
                ready = currentEpoch();
                if (!ready) break;
                final tail = _forkPromptTail(events);
                if (tail.sawBoundary || sawBoundary) {
                  sawBoundary = true;
                  if (tail.throughSeq != cursor) {
                    finish(null);
                  } else if (tail.first case final first?) {
                    observePrompt(first);
                  }
                } else {
                  for (final prompt in events.whereType<UserMessageEvent>()) {
                    if (_isOwnPrompt(prompt) && prompt.requestId == requestId) {
                      finish(prompt.seq);
                      break;
                    }
                  }
                }
              case final UserMessageEvent prompt when ready && currentEpoch() && _isOwnPrompt(prompt):
                observePrompt(prompt);
              case ConnectionStateEvent(:final state)
                  when state == DshConnectionState.idle ||
                      state == DshConnectionState.reconnecting ||
                      state == DshConnectionState.unauthorized ||
                      state == DshConnectionState.closed:
                finish(null);
              default:
                break;
            }
          },
          onError: (Object _, StackTrace _) => finish(null),
          onDone: () => finish(null),
        );
    final deadline = Timer(_receiptTimeout, () => finish(null));
    final seq = await receipt.future.whenComplete(() {
      deadline.cancel();
      return follow.cancel();
    });
    // Connection changes can be queued while the follow stream is closing.
    if (seq == null || hosts.closed || connections.closed) return null;
    final stillOwns = container.read(activeHostProvider) == host && owns(container.read(activeConnectionProvider));
    return stillOwns && !retired ? seq : null;
  } on StateError {
    // The provider scope can be disposed between the ACK and this read.
    return null;
  } on DshException {
    return null;
  } finally {
    clientChanges?.close();
    hostChanges?.close();
  }
}
