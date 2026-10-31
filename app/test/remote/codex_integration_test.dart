import 'dart:async';

import 'package:codex_backend/codex_backend.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';

import 'dart:typed_data';

import 'package:dsh_app/state/notify_state.dart' show appForegroundProvider;
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/codex_backend/test/support/fake_codex.dart' as codex;
import '../../../packages/codex_backend/test/support/fake_files.dart';
import '../chat/support/harness.dart' show testApp, usePhoneView;
import '../shell/golden_harness.dart' show FakeCurrentSession, FakeRuntime, runningStatus, goldenBoth;

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  test('old SSH configs remain DSH and Codex config round trips independently', () {
    final old = SshHostConfig.fromJson({'id': 'old', 'host': 'host', 'user': 'me'})!;
    expect(old.backend, RemoteBackend.dsh);
    final codex = old.copyWith(backend: RemoteBackend.codex, codexBinary: '/bin/codex', codexSocket: '/run/codex.sock');
    expect(SshHostConfig.fromJson(codex.toJson()), codex);
    expect(codex.connectionKey, isNot(old.connectionKey));
  });
  testWidgets('original ChatScreen uses real Codex adapter/controller, sends once and resolves approval', (
    tester,
  ) async {
    final wire = codex.Fake();
    final client = CodexChatClient(wire);
    await client.ready();
    addTearDown(client.close);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true))),
          advancedBackendProvider.overrideWithValue(false),
          currentSessionProvider.overrideWith(() => FakeCurrentSession('t')),
        ],
      ),
    );
    await frames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(container.read(chatProvider('t')).controlReady, isTrue);
    expect(find.text('world'), findsWidgets);
    expect(find.byType(AttachButton), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/codex_native_chat_light.png'));
    final sent = container.read(chatProvider('t').notifier).send('native test');
    await frames(tester);
    expect(await sent, isTrue);
    final request = wire.calls.lastWhere((c) => c.method == 'turn/start').args;
    wire.notify('item/completed', {
      'threadId': 't',
      'turnId': 'live',
      'item': {
        'id': 'echo',
        'clientId': request['clientUserMessageId'],
        'type': 'userMessage',
        'content': [
          {'type': 'text', 'text': 'native test'},
        ],
      },
    });
    await frames(tester);
    expect(container.read(chatProvider('t')).pending, isEmpty);
    wire.notify('item/commandExecution/requestApproval', {'threadId': 't', 'itemId': 'cmd', 'command': 'pwd'}, id: 19);
    await frames(tester);
    final approval = container.read(chatProvider('t')).approvals.single;
    await container.read(chatProvider('t').notifier).respond(approval, ApprovalDecision.reject);
    await frames(tester);
    expect(wire.answers.single['result'], {'decision': 'decline'});
    expect(container.read(chatProvider('t')).approvals, isEmpty);
    wire.notify('item/completed', {
      'threadId': 't',
      'turnId': 'live',
      'item': {
        'id': 'cmd',
        'type': 'commandExecution',
        'command': 'pwd',
        'status': 'completed',
        'aggregatedOutput': '/work',
      },
    });
    const answer = {'id': 'answer', 'type': 'agentMessage', 'text': 'Finished'};
    wire.notify('item/completed', {'threadId': 't', 'turnId': 'live', 'item': answer});
    await frames(tester);
    wire.notify('turn/completed', {
      'threadId': 't',
      'turn': {
        'id': 'live',
        'status': 'completed',
        'itemsView': 'summary',
        'items': [answer],
      },
    });
    await frames(tester);
    final completed = container.read(chatProvider('t'));
    expect(completed.running, isFalse);
    expect(completed.pending, isEmpty);
    expect(completed.items.whereType<UserChatItem>().last.text, 'native test');
    expect(completed.items.whereType<ToolChatItem>().single.callId, 'cmd');
    expect(completed.items.whereType<AssistantChatItem>().last.text, 'Finished');
    expect(find.text('native test'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(client.close);
    await frames(tester);
  });
  testWidgets('blank native chat creates a thread and sends the first message', (tester) async {
    final wire = codex.Fake()
      ..unpersisted = true
      ..turns = [];
    final client = CodexChatClient(wire);
    await client.ready();
    addTearDown(client.close);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          activeConnectionProvider.overrideWithValue(
            AsyncData(HostConnection(client: client, isLocal: false, workingDirectory: '/work')),
          ),
          advancedBackendProvider.overrideWithValue(false),
        ],
      ),
    );
    await frames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(container.read(currentSessionProvider), isNull);
    await tester.enterText(
      find.descendant(of: find.byType(Composer), matching: find.byType(EditableText)),
      'my first message',
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('发送'));
    await frames(tester);
    expect(container.read(currentSessionProvider), 't');
    expect(container.read(chatProvider('t')).controlReady, isTrue);
    expect(wire.calls.where((c) => c.method == 'thread/start'), hasLength(1));
    expect(wire.sends, 1);
    expect(wire.calls.singleWhere((c) => c.method == 'thread/start').args['cwd'], '/work');
    final sent = wire.calls.singleWhere((c) => c.method == 'turn/start');
    expect((sent.args['input'] as List).single['text'], 'my first message');
    expect(tester.widget<Composer>(find.byType(Composer)).busy, isFalse);
    expect(wire.calls.any((c) => c.method == 'thread/resume'), isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(client.close);
    await frames(tester);
  });
  testWidgets('Codex background cycle keeps its subscription and pending approvals', (tester) async {
    final wire = codex.Fake();
    wire.turns = [
      {
        'id': 'live',
        'status': 'inProgress',
        'items': [
          {'id': 'a', 'type': 'agentMessage', 'text': 'Still working'},
        ],
      },
    ];
    final client = CodexChatClient(wire);
    await client.ready();
    addTearDown(client.close);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: false))),
          advancedBackendProvider.overrideWithValue(false),
          currentSessionProvider.overrideWith(() => FakeCurrentSession('t')),
        ],
      ),
    );
    await frames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    int resumes() => wire.calls.where((c) => c.method == 'thread/resume').length;
    expect(container.read(chatProvider('t')).running, isTrue);
    expect(resumes(), 1);
    container.read(appForegroundProvider.notifier).set(false);
    await tester.pump(const Duration(seconds: 31));
    await frames(tester);
    expect(resumes(), 1, reason: 'Codex cannot disable token events; quiet relisten only reloads history');
    wire.notify('item/commandExecution/requestApproval', {'threadId': 't', 'itemId': 'cmd', 'command': 'pwd'}, id: 27);
    await frames(tester);
    expect(container.read(chatProvider('t')).approvals, hasLength(1));
    container.read(appForegroundProvider.notifier).set(true);
    await frames(tester);
    expect(resumes(), 1);
    expect(container.read(chatProvider('t')).controlReady, isTrue);
    expect(container.read(chatProvider('t')).approvals, hasLength(1));
    wire.notify('item/agentMessage/delta', {'threadId': 't', 'turnId': 'live', 'itemId': 'a', 'delta': ' done'});
    await frames(tester);
    expect(container.read(chatProvider('t')).items.whereType<AssistantChatItem>().single.text, 'Still working done');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(client.close);
    await frames(tester);
  });
  testWidgets('Codex reuses attachment sending and usage sheet', (tester) async {
    final wire = codex.Fake();
    final files = FakeFiles();
    final client = CodexChatClient(wire, files: files);
    await client.ready();
    addTearDown(client.close);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: false))),
          advancedBackendProvider.overrideWithValue(false),
          currentSessionProvider.overrideWith(() => FakeCurrentSession('t')),
          accountUsageProvider.overrideWith(
            (ref) async => {
              'rateLimits': {
                'limitName': 'Codex',
                'planType': 'pro',
                'primary': {'usedPercent': 12.0, 'windowDurationMins': 300, 'resetsAt': 1900000000},
              },
            },
          ),
        ],
      ),
    );
    await frames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final sending = container
        .read(chatProvider('t').notifier)
        .send(
          'with file',
          attachments: [
            DraftAttachment(name: 'report.txt', bytes: Uint8List.fromList([65, 66])),
          ],
        );
    await frames(tester);
    expect(await sending, isTrue);
    expect(files.data.values.single, [65, 66]);
    expect(wire.calls.lastWhere((c) => c.method == 'turn/start').args['input'].toString(), contains('report.txt'));
    wire.notify('thread/tokenUsage/updated', {
      'threadId': 't',
      'tokenUsage': {
        'total': {'inputTokens': 1000, 'cachedInputTokens': 250, 'outputTokens': 20},
        'last': {'totalTokens': 100},
        'modelContextWindow': 1000,
      },
    });
    await frames(tester);
    expect(container.read(sessionUsageProvider('t')).contextFraction, 0.1);
    expect(container.read(sessionUsageProvider('t')).input, 1000);
    await tester.tap(find.byType(ContextRing));
    await frames(tester);
    expect(find.byType(CodexQuotaCard), findsOneWidget);
    expect(find.textContaining('12.0%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(client.close);
    await frames(tester);
  });
  goldenBoth(
    'codex_native_form',
    () => const SshHostFormPage(
      existing: SshHostConfig(
        id: 'codex',
        name: 'Home Codex',
        host: '192.0.2.10',
        port: 22,
        user: 'demo',
        backend: RemoteBackend.codex,
      ),
    ),
  );
}
