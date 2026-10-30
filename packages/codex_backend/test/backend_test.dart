import 'dart:async';

import 'package:codex_backend/codex_backend.dart';

import 'support/fake_codex.dart';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

Future<void> settle() => Future.delayed(const Duration(milliseconds: 80));
void main() {
  late Fake wire;
  late CodexChatClient client;
  setUp(() async {
    wire = Fake();
    client = CodexChatClient(wire);
    await client.ready();
  });
  tearDown(() async {
    await client.close();
  });
  Future<({ChatTranscript transcript, StreamSubscription<DshEvent> sub})>
  watch() async {
    final transcript = ChatTranscript();
    final sub = client.watch('t').listen(transcript.apply);
    await settle();
    return (transcript: transcript, sub: sub);
  }

  test('real list and unsupported endpoints fail closed', () async {
    expect((await client.listSessions()).single.title, 'Native chat');
    expect(client.capabilities.advanced, isFalse);
    await expectLater(
      client.rpc.call('credentials/set', {}),
      throwsA(isA<DshRemoteException>()),
    );
    expect(wire.calls.any((c) => c.method.contains('credentials')), isFalse);
  });
  test('native history and pagination preserve identities', () async {
    wire.nextCursor = 'older';
    final w = await watch();
    expect(w.transcript.items.whereType<UserChatItem>().single.text, 'hello');
    expect(
      w.transcript.items.whereType<AssistantChatItem>().single.text,
      'world',
    );
    final key = w.transcript.items.last.key;
    final page = await client.history(
      't',
      throughSeq: w.transcript.cursor,
      beforeSeq: w.transcript.oldestSeq,
    );
    for (final e in page.events) w.transcript.apply(e);
    expect((w.transcript.items.first as UserChatItem).text, 'oldest');
    expect(w.transcript.items.last.key, key);
    await w.sub.cancel();
  });
  test('streaming text and completed items do not duplicate', () async {
    final w = await watch();
    wire.notify('turn/started', {
      'threadId': 't',
      'turn': {'id': 'live', 'status': 'inProgress', 'items': []},
    });
    wire.notify('item/started', {
      'threadId': 't',
      'turnId': 'live',
      'item': {'id': 'a2', 'type': 'agentMessage', 'text': ''},
    });
    wire.notify('item/agentMessage/delta', {
      'threadId': 't',
      'turnId': 'live',
      'itemId': 'a2',
      'delta': 'Hello',
    });
    await settle();
    expect(w.transcript.running, isTrue);
    expect(
      w.transcript.items.whereType<AssistantChatItem>().last.streaming,
      isTrue,
    );
    expect(
      w.transcript.items.whereType<AssistantChatItem>().last.text,
      'Hello',
    );
    wire.notify('item/completed', {
      'threadId': 't',
      'turnId': 'live',
      'item': {'id': 'a2', 'type': 'agentMessage', 'text': 'Hello!'},
    });
    wire.notify('turn/completed', {
      'threadId': 't',
      'turn': {'id': 'live', 'status': 'completed', 'items': []},
    });
    await settle();
    expect(w.transcript.running, isFalse);
    expect(w.transcript.items.whereType<AssistantChatItem>().length, 2);
    expect(
      w.transcript.items.whereType<AssistantChatItem>().last.text,
      'Hello!',
    );
    await w.sub.cancel();
  });
  for (final view in ['summary', 'notLoaded', 'unspecified']) {
    test(
      'completion $view preserves user, tools and stable item identities',
      () async {
        final w = await watch();
        final user = {
          'id': 'u-live',
          'type': 'userMessage',
          'clientId': 'phone-request',
          'content': [
            {'type': 'text', 'text': 'tool test'},
          ],
        };
        final commentary = {
          'id': 'commentary',
          'type': 'agentMessage',
          'text': 'Checking now',
        };
        final tool = {
          'id': 'cmd',
          'type': 'commandExecution',
          'command': 'pwd',
          'status': 'completed',
          'aggregatedOutput': '/work',
        };
        final answer = {
          'id': 'answer',
          'type': 'agentMessage',
          'text': 'Finished',
        };
        wire.notify('turn/started', {
          'threadId': 't',
          'turn': {
            'id': 'live',
            'status': 'inProgress',
            'items': [],
            'itemsView': 'notLoaded',
          },
        });
        for (final item in [user, commentary, tool, answer]) {
          wire.notify('item/completed', {
            'threadId': 't',
            'turnId': 'live',
            'item': item,
          });
        }
        await settle();
        final keys = w.transcript.items.map((i) => i.key).toList();
        final done = {
          'threadId': 't',
          'turn': {
            'id': 'live',
            'status': 'completed',
            if (view != 'unspecified') 'itemsView': view,
            'items': view == 'notLoaded' ? [] : [answer],
          },
        };
        wire.notify('turn/completed', done);
        await settle();
        expect(
          w.transcript.items.whereType<UserChatItem>().map((u) => u.text),
          ['hello', 'tool test'],
        );
        expect(
          w.transcript.items.whereType<UserChatItem>().last.requestId,
          'phone-request',
        );
        expect(
          w.transcript.items.whereType<ToolChatItem>().single.callId,
          'cmd',
        );
        expect(w.transcript.items.map((i) => i.key), keys);
        expect(w.transcript.running, isFalse);
        wire.notify('turn/completed', done);
        await settle();
        expect(w.transcript.items.map((i) => i.key), keys);
        // A fresh full history load agrees with the settled live transcript.
        wire.turns = [
          {
            'id': 'live',
            'status': 'completed',
            'itemsView': 'full',
            'items': [user, commentary, tool, answer],
          },
          ...wire.turns,
        ];
        await w.sub.cancel();
        final fresh = await watch();
        expect(fresh.transcript.items.map((i) => i.key), keys);
        await fresh.sub.cancel();
      },
    );
  }

  test('fresh unpersisted thread is ready before its first prompt', () async {
    wire.unpersisted = true;
    wire.turns = [];
    final created = await client.createSession(cwd: '/work');
    final transcript = ChatTranscript();
    final snapshots = <SessionSnapshotEvent>[];
    final errors = <Object>[];
    final sub = client.watch(created.sessionId).listen((e) {
      transcript.apply(e);
      if (e is SessionSnapshotEvent) snapshots.add(e);
    }, onError: errors.add);
    await settle();
    expect(errors, isEmpty);
    expect(snapshots, hasLength(1));
    expect(transcript.items, isEmpty);
    expect(
      (await client.listSessions()).map((s) => s.sessionId),
      contains(created.sessionId),
    );
    expect(
      wire.calls.any(
        (c) => c.method == 'thread/resume' || c.method == 'thread/turns/list',
      ),
      isFalse,
    );
    await client.setModel(
      created.sessionId,
      provider: 'codex',
      model: 'm',
      reasoningEffort: 'low',
    );
    await client.prompt(created.sessionId, 'first message', requestId: 'new-r');
    expect(wire.sends, 1);
    expect(wire.calls.last.args['model'], 'm');
    await sub.cancel();
    // Subsequent watches use normal history, not an indefinitely cached blank.
    final reopened = client
        .watch(created.sessionId)
        .listen((_) {}, onError: errors.add);
    await settle();
    expect(wire.calls.any((c) => c.method == 'thread/resume'), isTrue);
    expect(errors, isEmpty);
    await reopened.cancel();
  });

  test('uncertain send retry does not submit twice', () async {
    final w = await watch();
    wire.failSend = true;
    await expectLater(
      client.prompt('t', 'x', requestId: 'r'),
      throwsA(isA<DshTransportException>()),
    );
    await expectLater(
      client.prompt('t', 'x', requestId: 'r'),
      throwsA(isA<DshTransportException>()),
    );
    expect(wire.sends, 1);
    await w.sub.cancel();
  });
  test(
    'steer and stop target active turn, queue is not silently steered',
    () async {
      final w = await watch();
      await client.prompt('t', 'first', requestId: 'first');
      await client.prompt(
        't',
        'follow',
        requestId: 'second',
        mode: PromptMode.steer,
      );
      expect(wire.calls.last.args['expectedTurnId'], 'live');
      await expectLater(
        client.prompt('t', 'queue', requestId: 'third'),
        throwsA(isA<DshRemoteException>()),
      );
      await client.cancel('t');
      expect(wire.calls.last.method, 'turn/interrupt');
      expect(wire.calls.last.args['turnId'], 'live');
      await w.sub.cancel();
    },
  );
  test(
    'one-shot approvals use original id and reject duplicate response',
    () async {
      final w = await watch();
      wire.notify('item/commandExecution/requestApproval', {
        'threadId': 't',
        'itemId': 'cmd',
        'command': 'pwd',
      }, id: 17);
      await settle();
      final request = w.transcript.pendingApprovals.values.single;
      await client.respondApproval(request, ApprovalDecision.allowOnce);
      await settle();
      expect(wire.answers.single['id'], 17);
      expect(wire.answers.single['result'], {'decision': 'accept'});
      expect(w.transcript.pendingApprovals, isEmpty);
      await expectLater(
        client.respondApproval(request, ApprovalDecision.allowOnce),
        throwsA(isA<DshRemoteException>()),
      );
      await w.sub.cancel();
    },
  );
  test(
    'desktop resolution invalidates phone card; other threads untouched',
    () async {
      final w = await watch();
      wire.notify('item/fileChange/requestApproval', {
        'threadId': 't',
        'itemId': 'patch',
      }, id: 21);
      await settle();
      final stale = w.transcript.pendingApprovals.values.single;
      wire.notify('serverRequest/resolved', {'threadId': 't', 'requestId': 21});
      wire.notify('item/commandExecution/requestApproval', {
        'threadId': 'other',
        'itemId': 'cmd',
      }, id: 22);
      await settle();
      expect(w.transcript.pendingApprovals, isEmpty);
      expect(wire.answers, isEmpty);
      await expectLater(
        client.respondApproval(stale, ApprovalDecision.allowOnce),
        throwsA(isA<DshRemoteException>()),
      );
      await w.sub.cancel();
    },
  );
  test(
    'questions are answered; desktop dynamic tools are left to desktop',
    () async {
      final w = await watch();
      wire.notify('item/tool/requestUserInput', {
        'threadId': 't',
        'itemId': 'ask',
        'questions': [
          {'id': 'q', 'question': 'Choice?'},
        ],
      }, id: 'ask-id');
      await settle();
      await client.answerQuestion(w.transcript.pendingQuestions.values.single, [
        const QuestionAnswer('q', custom: 'Custom'),
      ]);
      expect(wire.answers.single['result'], {
        'answers': {
          'q': {
            'answers': ['Custom'],
          },
        },
      });
      wire.notify('item/tool/call', {
        'threadId': 't',
        'tool': 'desktop-only',
      }, id: 50);
      await settle();
      expect(wire.answers.length, 1);
      await w.sub.cancel();
    },
  );
  test('model validation and no global setting writes', () async {
    expect(
      (await client.listModels()).groups.single.models.single.efforts.single.id,
      'low',
    );
    await client.setModel(
      't',
      provider: 'codex',
      model: 'm',
      reasoningEffort: 'low',
    );
    await expectLater(
      client.setModel('t', provider: 'codex', model: 'fake'),
      throwsA(isA<DshRemoteException>()),
    );
    expect(wire.calls.any((c) => c.method.startsWith('config/')), isFalse);
  });
  test('archive never implicitly stops a running thread', () async {
    wire.thread['status'] = {'type': 'active'};
    await expectLater(
      client.archiveSession('t', stopActivity: true),
      throwsA(isA<DshRemoteException>()),
    );
    expect(
      wire.calls.any(
        (c) => c.method == 'turn/interrupt' || c.method == 'thread/archive',
      ),
      isFalse,
    );
  });
  test(
    'account refresh for same login stays connected; account switch closes',
    () async {
      wire.notify('account/updated', {});
      await settle();
      expect(wire.end.isCompleted, isFalse);
      wire.account = {'type': 'chatgpt', 'email': 'other@example.invalid'};
      wire.notify('account/updated', {});
      await settle();
      expect(wire.end.isCompleted, isTrue);
    },
  );
  test(
    'unknown send outcome remains deduplicated after client replacement',
    () async {
      final ledger = <String, Future<String>>{};
      final firstWire = Fake()..failSend = true;
      final first = CodexChatClient(firstWire, submissionLedger: ledger);
      await first.ready();
      await expectLater(
        first.prompt('t', 'x', requestId: 'shared'),
        throwsA(isA<DshTransportException>()),
      );
      await first.close();
      final secondWire = Fake();
      final second = CodexChatClient(secondWire, submissionLedger: ledger);
      await second.ready();
      await expectLater(
        second.prompt('t', 'x', requestId: 'shared'),
        throwsA(isA<DshTransportException>()),
      );
      expect(firstWire.sends, 1);
      expect(secondWire.sends, 0);
      await second.close();
    },
  );
  test(
    'hydration does not replay started item or delta over newer snapshot',
    () async {
      wire.turns = [
        {
          'id': 'live',
          'status': 'inProgress',
          'items': [
            {'id': 'a2', 'type': 'agentMessage', 'text': 'Hello'},
          ],
        },
      ];
      wire.onPage = () {
        wire.notify('item/started', {
          'threadId': 't',
          'turnId': 'live',
          'item': {'id': 'a2', 'type': 'agentMessage', 'text': ''},
        });
        wire.notify('item/agentMessage/delta', {
          'threadId': 't',
          'turnId': 'live',
          'itemId': 'a2',
          'delta': 'Hello',
        });
      };
      final w = await watch();
      expect(
        w.transcript.items.whereType<AssistantChatItem>().single.text,
        'Hello',
      );
      await w.sub.cancel();
    },
  );
  test('create rename archive and restore use Codex methods', () async {
    final created = await client.createSession(cwd: '/work');
    expect(created.sessionId, 't');
    await client.renameSession('t', 'Renamed');
    expect((await client.listSessions()).single.title, 'Renamed');
    expect(await client.archiveSession('t'), contains('t'));
    expect(await client.unarchiveSession('t'), isEmpty);
    expect(
      wire.calls.map((c) => c.method),
      containsAll([
        'thread/start',
        'thread/name/set',
        'thread/archive',
        'thread/unarchive',
      ]),
    );
  });
}
