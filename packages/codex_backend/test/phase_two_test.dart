import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_backend/codex_backend.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_codex.dart';
import 'support/fake_files.dart';

void main() {
  late Fake wire;
  late FakeFiles files;
  late CodexChatClient client;
  setUp(() async {
    wire = Fake();
    files = FakeFiles();
    client = CodexChatClient(wire, files: files);
    await client.ready();
  });
  tearDown(() => client.close());
  test(
    'mixed input uses uploaded image and scoped file, echoes survive history',
    () async {
      final file = await client.uploadFile('t', [1, 2, 3], name: '资料.txt');
      final image = PromptImage.fromBytes(
        [137, 80, 78, 71],
        mediaType: 'image/png',
        name: 'photo.png',
      );
      await client.prompt(
        't',
        'read these',
        images: [image],
        fileReceiptIds: [file.receiptId],
        requestId: 'once',
      );
      final args = wire.calls.lastWhere((c) => c.method == 'turn/start').args;
      final input = rows(args['input']);
      expect(input[0]['text'], contains('资料.txt'));
      expect(input[1]['type'], 'localImage');
      expect(files.data[input[1]['path']], [137, 80, 78, 71]);
      await client.prompt(
        't',
        'read these',
        images: [image],
        fileReceiptIds: [file.receiptId],
        requestId: 'once',
      );
      expect(wire.sends, 1);
      expect(files.data.length, 2);
      wire.turns = [
        {
          'id': 'sent',
          'status': 'completed',
          'items': [
            {'id': 'user', 'type': 'userMessage', 'content': input},
          ],
        },
      ];
      final transcript = ChatTranscript();
      final sub = client.watch('t').listen(transcript.apply);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final user = transcript.items.whereType<UserChatItem>().last;
      expect(user.text, 'read these');
      expect(user.files.single.name, '资料.txt');
      expect(user.images, hasLength(1));
      expect(
        (await client.attachment('t', user.images.single.attachmentId)).bytes,
        [137, 80, 78, 71],
      );
      await sub.cancel();
      await expectLater(
        client.prompt('other', 'x', fileReceiptIds: [file.receiptId]),
        throwsA(isA<DshRemoteException>()),
      );
    },
  );
  test(
    'tool image bytes render as attachments without dumping base64 into text',
    () async {
      wire.turns = [
        {
          'id': 'tools',
          'status': 'completed',
          'items': [
            {
              'id': 'img',
              'type': 'dynamicToolCall',
              'tool': 'imagegen',
              'status': 'completed',
              'success': true,
              'arguments': {},
              'contentItems': [
                {'type': 'inputText', 'text': 'done'},
                {
                  'type': 'inputImage',
                  'imageUrl': 'data:image/png;base64,AQID',
                },
              ],
            },
            {
              'id': 'gen',
              'type': 'imageGeneration',
              'status': 'completed',
              'result': 'BAUG',
            },
          ],
        },
      ];
      final transcript = ChatTranscript();
      final sub = client.watch('t').listen(transcript.apply);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final tools = transcript.items.whereType<ToolChatItem>().toList();
      expect(tools.first.resultText, 'done');
      final image = tools.first.resultParts.whereType<ImagePart>().single;
      expect(
        (await client.attachment('t', image.attachment.attachmentId)).bytes,
        [1, 2, 3],
      );
      final generated = tools.last.resultParts.whereType<ImagePart>().single;
      expect(
        (await client.attachment('t', generated.attachment.attachmentId)).bytes,
        [4, 5, 6],
      );
      await sub.cancel();
    },
  );
  test(
    'original file API reads bounded windows, resolves cwd, rejects oversize',
    () async {
      files.data['/work/chart.png'] = Uint8List(1024 * 1024 + 7)..last = 99;
      final bytes = await client.readFileBytes(
        't',
        'chart.png',
        maxBytes: 2 * 1024 * 1024,
      );
      expect(bytes.length, 1024 * 1024 + 7);
      expect(bytes.last, 99);
      expect(files.reads.map((r) => r.offset), [0, 1024 * 1024]);
      files.reads.clear();
      await expectLater(
        client.readFileBytes('t', 'chart.png', maxBytes: 10),
        throwsA(isA<DshRemoteException>()),
      );
      expect(files.reads, isEmpty);
    },
  );
  test(
    'original text and CSV preview APIs have metadata and bounded pages',
    () async {
      files.data['/work/readme.md'] = Uint8List.fromList(
        utf8.encode('第一行\nsecond\nthird\n'),
      );
      final page = await client.readWorkspaceText(
        't',
        'readme.md',
        offset: 2,
        limit: 1,
      );
      expect(page.text, 'second');
      expect(page.lines, 1);
      expect(page.eof, isFalse);
      final window = await client.readWorkspaceWindow(
        't',
        'readme.md',
        length: 2 * 1024 * 1024,
      );
      expect(window.absolutePath, '/work/readme.md');
      expect(window.version, '1');
      expect(window.eof, isTrue);
      files.data['/work/large.txt'] = Uint8List(2 * 1024 * 1024 + 1);
      await expectLater(
        client.readWorkspaceText('t', 'large.txt'),
        throwsA(
          isA<DshRemoteException>().having(
            (e) => e.code,
            'code',
            'workspace-file/too-large',
          ),
        ),
      );
    },
  );
  test('server content search uses only listed rollout paths and reports partial scans', () async {
    wire.thread['path'] = '/rollouts/t.jsonl';
    files.result = {
      'items': [
        {'sessionId': 't', 'snippet': 'needle'},
      ],
      'hasMore': true,
    };
    final found = await client.searchSessionsPage('needle');
    expect(found.items.single.sessionId, 't');
    expect(found.hasMore, isTrue);
    expect(files.inspection!['threads'], [
      {'id': 't', 'path': '/rollouts/t.jsonl'},
    ]);
    expect(client.supportsEndpoint('session/search'), isTrue);
  });
  test(
    'live usage maps cached input once and survives later projection reads',
    () async {
      final events = <SessionControlUpdate>[];
      final sub = client.watchSessionControl().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      wire.notify('thread/tokenUsage/updated', {
        'threadId': 't',
        'tokenUsage': {
          'total': {
            'inputTokens': 1000,
            'cachedInputTokens': 300,
            'cacheWriteInputTokens': 100,
            'outputTokens': 50,
          },
          'last': {'totalTokens': 200},
          'modelContextWindow': 10000,
        },
      });
      await Future<void>.delayed(Duration.zero);
      final p = (await client.projections('t'))!;
      expect((p.values['tokenUsage'] as Map)['uncachedInputTokens'], 600);
      expect((p.values['contextPressure'] as Map)['pressureTokens'], 200);
      expect(events.whereType<SessionControlProjection>(), hasLength(2));
      expect(p.asOfSeq, greaterThan(0));
      await sub.cancel();
    },
  );
  test(
    'historical usage seeds from last persisted token count without inference',
    () async {
      wire.thread['path'] = '/rollouts/t.jsonl';
      files.result = {
        'usage': {
          'total_token_usage': {
            'input_tokens': 90,
            'cached_input_tokens': 50,
            'output_tokens': 10,
          },
          'last_token_usage': {'total_tokens': 70},
          'model_context_window': 1000,
        },
      };
      final p = (await client.projections('t'))!;
      expect((p.values['tokenUsage'] as Map)['uncachedInputTokens'], 40);
      expect((p.values['contextPressure'] as Map)['contextWindow'], 1000);
    },
  );
}
