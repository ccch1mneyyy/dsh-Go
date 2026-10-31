// Codex pet answers must use the typed adapter and preserve request identity.
import 'package:codex_backend/codex_backend.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/codex_backend/test/support/fake_codex.dart' as codex;
import 'support.dart';

class _Local extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

void main() {
  test('Codex single-choice pet answer reaches the Codex server', () async {
    SharedPreferences.setMockInitialValues({});
    final wire = codex.Fake();
    final client = CodexChatClient(wire);
    await client.ready();
    final watch = client.watch('t').listen((_) {});
    await settle();
    final source = FakeAlertSource()..sessions = [session('t')];
    final channel = FakeNotifyChannel();
    final events = <PetEvent>[];
    final requests = <UserQuestionRequest>[];
    final hostEvents = client.hostEvents.listen((event) {
      if (event is UserQuestionRequestedEvent) requests.add(event.request);
      source.emit(event);
    });
    final container = ProviderContainer(
      overrides: [
        notifyChannelProvider.overrideWithValue(channel),
        alertSourceFactoryProvider.overrideWithValue((_) => source),
        alertTimingProvider.overrideWithValue((announce: Duration.zero, reconcile: const Duration(milliseconds: 30))),
        localConnectionProvider.overrideWith(_Local.new),
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(client: client, label: 'Demo', isLocal: false, kind: HostKind.ssh, hostId: 'demo')),
        ),
      ],
    );
    final petEvents = container.read(petEventBusProvider).events.listen(events.add);
    addTearDown(() async {
      container.dispose();
      await petEvents.cancel();
      await hostEvents.cancel();
      await watch.cancel();
      await channel.actionController.close();
      await channel.tapController.close();
      await client.close();
    });
    container.listen(chatAlertsProvider, (_, _) {});
    container.read(appForegroundProvider.notifier).set(false);
    await settle();
    wire.notify('item/tool/requestUserInput', {
      'threadId': 't',
      'itemId': 'ask',
      'questions': [
        {
          'id': 'color',
          'question': 'Pick a color',
          'options': [
            {'label': 'Blue'},
            {'label': 'Red'},
          ],
        },
      ],
    }, id: 42);
    await settle();
    expect(requests, hasLength(1));
    final ask = events.lastWhere((event) => event.ask?.choices.isNotEmpty == true).ask!;
    expect(ask.choices, ['Blue', 'Red']);
    for (final invalid in [(ask.token! + 1, 'Blue'), (ask.token!, 'Unknown')]) {
      final rejected = await container
          .read(chatAlertsProvider.notifier)
          .answerFromPet(
            const HostRef.ssh('demo'),
            requests.single.eventId,
            sessionId: 't',
            token: invalid.$1,
            choice: invalid.$2,
          );
      expect(rejected, isNot(NotifyActionResult.handled));
      expect(wire.answers, isEmpty);
    }
    final result = await container
        .read(chatAlertsProvider.notifier)
        .answerFromPet(
          const HostRef.ssh('demo'),
          requests.single.eventId,
          sessionId: 't',
          token: ask.token!,
          choice: 'Blue',
        );
    expect(wire.answers, hasLength(1));
    expect(wire.answers.single['id'], 42);
    expect(wire.answers.single['result'], {
      'answers': {
        'color': {
          'answers': ['Blue'],
        },
      },
    });
    await settle();
    final replay = await container
        .read(chatAlertsProvider.notifier)
        .answerFromPet(
          const HostRef.ssh('demo'),
          requests.single.eventId,
          sessionId: 't',
          token: ask.token!,
          choice: 'Blue',
        );
    expect(replay, NotifyActionResult.gone);
    expect(wire.answers, hasLength(1));
    expect(result, NotifyActionResult.handled);
  });
}
