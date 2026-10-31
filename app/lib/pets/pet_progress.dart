// One passive, host-bound session watch for the out-of-app pet. Only phase
// and tool name cross the overlay channel; never narration or tool arguments.
import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../plugins/native/native_state.dart' show nativeLocaleProvider;
import '../state/chat_state.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show appForegroundProvider;
import '../state/run_pulse.dart' show compactingAfter;
import '../ui/chat/run_info.dart';
import 'overlay_channel.dart';
import 'pet_mood.dart';
import 'pet_prefs.dart';
import 'pet_signals.dart';
import 'pet_state.dart';

/// Prefer the last viewed run, then keep the tracked run to avoid hopping
/// between concurrent sessions. Session ids are always scoped to a host.
PetTarget? petProgressTarget(List<PetRun> runs, {PetTarget? preferred, PetTarget? previous}) {
  final top = runs.where((r) => !r.subagent);
  for (final target in [preferred, previous]) {
    if (target != null && top.any((r) => r.host == target.host && r.sessionId == target.sessionId)) return target;
  }
  PetRun? recent;
  for (final run in top) {
    if (recent == null || (run.since != null && (recent.since == null || run.since!.isAfter(recent.since!)))) {
      recent = run;
    }
  }
  return recent == null ? null : PetTarget(recent.host, recent.sessionId);
}

String petProgressText(RunActivity activity, {L10n? l10n}) {
  final words = l10n ?? appL10n;
  return switch (activity.kind) {
    ActivityKind.waiting || ActivityKind.thinking => words.statePetThinking,
    ActivityKind.writing => words.statePetWriting,
    ActivityKind.tool => _toolProgressText(activity.toolName, words),
    ActivityKind.approval => words.commonWaitingApproval,
    ActivityKind.question => words.commonWaitingAnswer,
    ActivityKind.stopping => words.commonStopping,
    ActivityKind.retry => words.activityRetrying,
    ActivityKind.compaction => words.activityCompacting,
  };
}

String _toolProgressText(String? toolName, L10n words) {
  final name = (toolName ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (name.isEmpty) return words.activityToolCall;
  final points = name.runes.toList();
  final short = points.length > 32 ? '${String.fromCharCodes(points.take(31))}…' : name;
  return words.statePetCallingTool(short);
}

class PetProgressTargetController extends Notifier<PetTarget?> {
  PetTarget? _preferred;
  PetTarget? _previous;

  @override
  PetTarget? build() {
    final focus = ref.watch(petFocusProvider);
    if (focus != null) _preferred = focus.target;
    return _previous = petProgressTarget(ref.watch(petRunsProvider), preferred: _preferred, previous: _previous);
  }
}

final petProgressTargetProvider = NotifierProvider<PetProgressTargetController, PetTarget?>(
  PetProgressTargetController.new,
);

/// Rebuilds the passive watch for each ready connection generation.
///
/// [DshClient.watch] closes after exhausting its own retry budget. The client
/// survives a mux reconnect, so without this dependency Riverpod keeps the
/// failed stream provider and the overlay cannot resume progress.
final petProgressReadyGenerationsProvider = StreamProvider.autoDispose.family<int, Stream<MuxGeneration>>(
  (ref, generations) => generations.map((generation) => generation.number),
);

/// A seam for event fixtures; passive follow never activates a session.
final petProgressEventsProvider = Provider.autoDispose.family<Stream<DshEvent>?, PetTarget>((ref, target) {
  if (!target.host.isLocal && ref.watch(activeHostProvider) != target.host) return null;
  final connection = target.host.isLocal
      ? ref.watch(localConnectionProvider).asData?.value
      : ref.watch(activeConnectionProvider).asData?.value;
  final client = connection?.client;
  if (client == null) return null;
  ref.watch(petProgressReadyGenerationsProvider(client.mux.generations));
  return client.watch(
    target.sessionId,
    options: const WatchOptions(turnWindow: TurnWindow(1, 1), maxMessages: 100, includeSyncEvents: true),
  );
});

/// Retire stale text immediately on loss/resync; a new snapshot makes it live.
Stream<RunActivity?> petProgressActivities(Stream<DshEvent> events) {
  final transcript = ChatTranscript();
  var ready = false;
  DateTime? compacting;
  // A transformer forwards cancellation even while the source is silent.
  return events.transform(
    StreamTransformer<DshEvent, RunActivity?>.fromHandlers(
      handleData: (event, sink) {
        if (event is SessionSyncEvent ||
            (event is ConnectionStateEvent && event.state != DshConnectionState.connected)) {
          ready = false;
          compacting = null;
          sink.add(null);
          return;
        }
        if (event is SessionSnapshotEvent) {
          ready = true;
          compacting = compactingAfter(event.events, null, false);
        } else if (event is SessionLogEvent) {
          compacting = compactingAfter([event], compacting, true);
        }
        transcript.apply(event);
        if (!ready) return;
        final state = ChatState(
          running: transcript.running,
          items: transcript.items,
          approvals: transcript.pendingApprovals.values.toList(),
          questions: transcript.pendingQuestions.values.toList(),
          turns: transcript.turns,
        );
        final since = compacting;
        sink.add(since == null ? runActivityOf(state) : compactionActivity(state, since));
      },
      handleError: (_, _, sink) {
        sink.add(null);
        sink.close();
      },
      handleDone: (sink) {
        sink.add(null);
        sink.close();
      },
    ),
  );
}

final petProgressActivityProvider = StreamProvider.autoDispose.family<RunActivity?, PetTarget>((ref, target) {
  final events = ref.watch(petProgressEventsProvider(target));
  return events == null ? Stream.value(null) : petProgressActivities(events);
});

final petProgressProvider = Provider<PetProgress?>((ref) {
  // Keep selection warm in the foreground, but open no extra session stream.
  final target = ref.watch(petProgressTargetProvider);
  final prefs = ref.watch(petPrefsProvider);
  if (target == null || prefs.packId == noPetId || prefs.quiet || ref.watch(appForegroundProvider)) return null;
  final overlay = ref.watch(petOverlayProvider);
  if (!overlay.working || overlay.snoozed) return null;
  final activity = ref.watch(petProgressActivityProvider(target)).asData?.value;
  if (activity == null) return null;
  final locale = ref.watch(nativeLocaleProvider) == 'en' ? AppLocale.en : AppLocale.zhCN;
  return PetProgress(
    text: petProgressText(activity, l10n: lookupL10n(locale)),
    target: target,
  );
});
