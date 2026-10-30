import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_progress.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dsh_app/pets/overlay_channel.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/state/notify_state.dart' show appForegroundProvider;

import 'support.dart' show FixedPetPrefs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = PetTarget(HostRef.local, 'a');
  const b = PetTarget(HostRef.local, 'b');
  const runs = [PetRun(HostRef.local, 'a'), PetRun(HostRef.local, 'b')];

  test('prefers the viewed running session, then keeps the tracked run', () {
    expect(petProgressTarget(runs, preferred: a, previous: b), a);
    expect(petProgressTarget(runs, previous: b), b);
    expect(petProgressTarget([runs.last], preferred: a, previous: a), b);
    expect(petProgressTarget([], preferred: a, previous: a), isNull);
  });

  test('uses host identity and ignores subagents as top-level targets', () {
    const remote = HostRef.ssh('pc');
    const other = PetTarget(remote, 'a');
    expect(petProgressTarget([const PetRun(remote, 'a')], preferred: a), other);
    expect(petProgressTarget([const PetRun(HostRef.local, 'child', subagent: true)]), isNull);
    final newer = PetRun(HostRef.local, 'b', since: DateTime(2026, 10, 30));
    expect(petProgressTarget([runs.first, newer]), b);
  });

  test('tool progress contains only its name, bounded to one short line', () {
    final text = petProgressText(
      const RunActivity(
        kind: ActivityKind.tool,
        title: 'ignored',
        toolName: 'read_file',
        detail: '/private/secret.txt',
        narration: 'private reasoning',
      ),
    );
    expect(text, '正在调用：read_file');
    expect(text, isNot(contains('private')));
    expect(
      petProgressText(RunActivity(kind: ActivityKind.tool, title: '', toolName: 'x' * 200)).length,
      lessThanOrEqualTo(48),
    );
    expect(petProgressText(const RunActivity(kind: ActivityKind.tool, title: '', toolName: ' a\n b ')), '正在调用：a b');
  });

  test('phase labels follow the app language and distinguish writing', () {
    String label(ActivityKind kind) => petProgressText(RunActivity(kind: kind, title: 'ignored'));
    expect(label(ActivityKind.thinking), '正在思考');
    expect(label(ActivityKind.writing), '正在生成回复');
    expect(label(ActivityKind.approval), appL10n.commonWaitingApproval);
    expect(label(ActivityKind.question), appL10n.commonWaitingAnswer);
    AppLocale.use(AppLocale.en);
    try {
      expect(label(ActivityKind.thinking), 'Thinking');
      expect(
        petProgressText(const RunActivity(kind: ActivityKind.tool, title: '', toolName: 'read_file')),
        'Calling: read_file',
      );
    } finally {
      AppLocale.use(AppLocale.zhCN);
    }
  });

  test('progress participates in state equality and carries its own target', () {
    const progress = PetProgress(text: '正在思考', target: a);
    const base = PetState(canStop: true, hosts: [PetHostChoice(HostRef.local, '本机', current: true)]);
    final state = base.withProgress(progress);
    expect(state, isNot(const PetState()));
    expect(state.canStop, isTrue);
    expect(state.hosts, const [PetHostChoice(HostRef.local, '本机', current: true)]);
    expect(state.toMap()['progress'], {'text': '正在思考', 'target': a.toMap()});
    expect(const PetState().toMap().containsKey('progress'), isFalse);
  });

  test('passive progress clears on reconnect, resync, turn end and stream error', () async {
    final time = DateTime(2026, 10, 30);
    final snapshot = SessionSnapshotEvent.fromJson('a', {
      'records': [
        {
          'event': {
            'seq': 0,
            'time': time.millisecondsSinceEpoch,
            'type': 'turn/start',
            'data': {'turn': 1},
          },
        },
      ],
      'cursor': 0,
    });
    final events = StreamController<DshEvent>();
    final seen = <RunActivity?>[];
    final sub = petProgressActivities(events.stream).listen(seen.add);
    events.add(snapshot);
    await pumpEventQueue();
    expect(seen.last?.kind, ActivityKind.waiting);
    events.add(const ConnectionStateEvent(DshConnectionState.reconnecting));
    await pumpEventQueue();
    expect(seen.last, isNull);
    events.add(const ConnectionStateEvent(DshConnectionState.connected));
    await pumpEventQueue();
    expect(seen.last, isNull, reason: 'connected alone does not revive stale text');
    events.add(snapshot);
    events.add(SessionSyncEvent(SessionFollowEpoch()));
    await pumpEventQueue();
    expect(seen.last, isNull);
    events.add(snapshot);
    events.add(TurnEndedEvent(1, time, const {}, turn: 1, reason: const TurnEndReason('completed')));
    await pumpEventQueue();
    expect(seen.last, isNull);
    events.addError(StateError('disconnected'));
    await pumpEventQueue();
    expect(seen.last, isNull);
    await sub.cancel();
    await events.close();
  });

  test('realistic follow frames produce waiting and named tool phases', () async {
    final events = File('test/chat/fixtures/follow_run_info.jsonl')
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => parseFollowFrame('s1', jsonDecode(line)));
    final phases = await petProgressActivities(Stream.fromIterable(events)).toList();
    expect(phases.any((p) => p?.kind == ActivityKind.waiting || p?.kind == ActivityKind.thinking), isTrue);
    expect(phases.any((p) => p?.kind == ActivityKind.tool && p?.toolName?.isNotEmpty == true), isTrue);
    expect(phases.last, isNull, reason: 'closed follow must clear its last tool');
  });

  test('live assistant chunks distinguish reasoning from reply text', () async {
    final time = DateTime(2026, 10, 30);
    final snapshot = SessionSnapshotEvent.fromJson('a', {
      'records': [
        {
          'event': {
            'seq': 0,
            'time': time.millisecondsSinceEpoch,
            'type': 'turn/start',
            'data': {'turn': 1},
          },
        },
      ],
      'cursor': 0,
    });
    final phases = await petProgressActivities(
      Stream.fromIterable(<DshEvent>[
        snapshot,
        const AssistantStreamStarted('live', 1, turn: 1, step: 1, startedAfterSeq: 0),
        AssistantChunkEvent('live', 2, index: 0, time: time, chunk: const ReasoningDeltaChunk(0, 'private reasoning')),
        AssistantChunkEvent('live', 3, index: 1, time: time, chunk: const TextDeltaChunk(1, 'reply text')),
      ]),
    ).toList();
    expect(phases.any((p) => p?.kind == ActivityKind.thinking), isTrue);
    expect(phases.any((p) => p?.kind == ActivityKind.writing), isTrue);
  });

  test('only the tracked background session is watched and gate changes cancel it', () async {
    var listens = 0;
    var cancels = 0;
    final events = StreamController<DshEvent>.broadcast(onListen: () => listens++, onCancel: () => cancels++);
    final container = ProviderContainer(
      overrides: [
        petProgressTargetProvider.overrideWith(() => _Target(a)),
        petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(quiet: false))),
        petOverlayProvider.overrideWith(_Overlay.new),
        petProgressEventsProvider.overrideWith((ref, target) {
          expect(target, a);
          return events.stream;
        }),
      ],
    );
    final sub = container.listen(petProgressProvider, (_, _) {});
    expect(listens, 0, reason: 'foreground should open no progress stream');
    container.read(appForegroundProvider.notifier).set(false);
    await pumpEventQueue();
    expect(listens, 1);
    container.read(appForegroundProvider.notifier).set(true);
    await container.pump();
    await pumpEventQueue();
    expect(cancels, 1);
    expect(container.read(petProgressProvider), isNull);
    container.read(appForegroundProvider.notifier).set(false);
    await pumpEventQueue();
    expect(listens, 2);
    await container.read(petPrefsProvider.notifier).setQuiet(true);
    await pumpEventQueue();
    expect(cancels, 2);
    await container.read(petPrefsProvider.notifier).setQuiet(false);
    await pumpEventQueue();
    expect(listens, 3);
    (container.read(petOverlayProvider.notifier) as _Overlay).disable();
    await pumpEventQueue();
    expect(cancels, 3);
    sub.close();
    container.dispose();
    await events.close();
  });
}

class _Target extends PetProgressTargetController {
  _Target(this.target);
  final PetTarget target;
  @override
  PetTarget? build() => target;
}

class _Overlay extends PetOverlayController {
  @override
  PetOverlayStatus build() => const PetOverlayStatus(enabled: true, permission: PetOverlayPermission.granted);
  void disable() => state = const PetOverlayStatus(enabled: false);
}
