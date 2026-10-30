import 'dart:convert';
import 'dart:io';

import 'package:codex_client/host_files.dart';
import 'package:test/test.dart';

void main() {
  test(
    'bounded server scan folds case/width, ignores tools and finds last usage',
    () async {
      final dir = await Directory.systemTemp.createTemp('codex-search-test-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/history.jsonl';
      final rows = [
        {
          'type': 'response_item',
          'payload': {'type': 'function_call', 'text': 'secretneedle'},
        },
        {
          'type': 'response_item',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'ＡＢＣ 中文 needle'},
            ],
          },
        },
        {
          'type': 'event_msg',
          'payload': {
            'type': 'token_count',
            'info': {
              'total_token_usage': {'input_tokens': 123},
            },
          },
        },
      ];
      await File(path).writeAsString('${rows.map(jsonEncode).join('\n')}\n');
      Future<Map<String, dynamic>> run(Map<String, dynamic> request) async {
        final p = await Process.start('python3', ['-c', rolloutInspector]);
        final out = p.stdout.transform(utf8.decoder).join();
        p.stdin.write(
          jsonEncode({
            ...request,
            'threads': [
              {'id': 't', 'path': path},
            ],
          }),
        );
        await p.stdin.close();
        expect(await p.exitCode, 0);
        return jsonDecode(await out) as Map<String, dynamic>;
      }

      expect((await run({'query': 'abc 中文'}))['items'], hasLength(1));
      expect((await run({'query': 'secretneedle'}))['items'], isEmpty);
      expect(
        (await run({
          'usage': true,
        }))['usage']['total_token_usage']['input_tokens'],
        123,
      );
    },
  );
}
