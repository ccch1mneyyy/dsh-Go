import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:codex_client/codex_client.dart';
import 'package:test/test.dart';

Future<CodexClient> fixture(
  void Function(Map<String, dynamic>, WebSocket) handle, {
  bool splitBytes = false,
  bool subviews = false,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  WebSocket? peer;
  server.listen((request) async {
    peer = await WebSocketTransformer.upgrade(request);
    peer!.listen(
      (raw) => handle(
        Map<String, dynamic>.from(jsonDecode(raw as String) as Map),
        peer!,
      ),
    );
  });
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
  );
  final client = await CodexClient.connect(
    input: splitBytes
        ? socket.asyncExpand(
            (bytes) => Stream.fromIterable(bytes.map((b) => [b])),
          )
        : subviews
        ? socket.map((bytes) {
            final storage = Uint8List(bytes.length + 37)
              ..setRange(37, bytes.length + 37, bytes);
            return Uint8List.sublistView(storage, 37);
          })
        : socket,
    write: socket.add,
    closeTransport: socket.destroy,
  );
  addTearDown(() async {
    await client.close();
    await peer?.close();
    await server.close(force: true);
  });
  return client;
}

void result(
  WebSocket ws,
  Map<String, dynamic> req,
  Map<String, dynamic> data,
) => ws.add(jsonEncode({'id': req['id'], 'result': data}));

void main() {
  test(
    'null mutation response and interleaved server requests preserve ids',
    () async {
      final response = Completer<Map<String, dynamic>>();
      final client = await fixture((req, ws) {
        if (req['method'] == null) {
          response.complete(req);
          return;
        }
        ws.add(
          jsonEncode({
            'id': 'approve-1',
            'method': 'item/commandExecution/requestApproval',
            'params': {'threadId': 't'},
          }),
        );
        ws.add(jsonEncode({'id': req['id'], 'result': null}));
      });
      final events = <Map<String, dynamic>>[];
      final sub = client.messages.listen(events.add);
      expect(
        await client.request('thread/name/set', {
          'threadId': 't',
          'name': 'Test',
        }),
        isEmpty,
      );
      expect(events.single['id'], 'approve-1');
      client.respond('approve-1', result: {'decision': 'decline'});
      expect((await response.future)['result'], {'decision': 'decline'});
      await sub.cancel();
    },
  );
  test(
    'RPC failure remains a server rejection rather than an unknown send',
    () async {
      final client = await fixture(
        (req, ws) => ws.add(
          jsonEncode({
            'id': req['id'],
            'error': {'code': -32602, 'message': 'invalid model'},
          }),
        ),
      );
      await expectLater(
        client.request('turn/start', {}),
        throwsA(isA<CodexRpcException>().having((e) => e.code, 'code', -32602)),
      );
    },
  );

  test('decodes SSH byte subviews with a non-zero buffer offset', () async {
    final client = await fixture(
      (req, ws) => result(ws, req, {
        'account': {'type': 'chatgpt'},
      }),
      subviews: true,
    );
    expect((await client.account())['account']['type'], 'chatgpt');
  });
  test(
    'malformed response fails the pending call without waiting for timeout',
    () async {
      final client = await fixture(
        (req, ws) => ws.add(jsonEncode({'id': req['id'], 'result': []})),
      );
      await expectLater(
        client.account().timeout(const Duration(seconds: 1)),
        throwsA(isNot(isA<TimeoutException>())),
      );
      await client.done;
    },
  );

  test('fragmented upgrade and frames, initialize and full history; only read methods', () async {
    final methods = <String>[];
    final client = await fixture((req, ws) {
      methods.add(req['method'] as String);
      switch (req['method']) {
        case 'initialize':
          result(ws, req, {});
        case 'account/read':
          expect(req['params']['refreshToken'], isFalse);
          result(ws, req, {
            'account': {'type': 'chatgpt'},
          });
        case 'thread/list':
          expect(req['params']['useStateDbOnly'], isTrue);
          result(ws, req, {
            'data': [
              {'id': 't1'},
            ],
            'nextCursor': 'page2',
          });
        case 'thread/turns/list':
          expect(req['params']['itemsView'], 'full');
          expect(req['params']['cursor'], 'older');
          result(ws, req, {
            'data': [
              {
                'id': 'turn',
                'items': [
                  {'type': 'agentMessage', 'text': '你好'},
                ],
              },
            ],
          });
      }
    }, splitBytes: true);
    await client.initialize();
    expect((await client.account())['account']['type'], 'chatgpt');
    expect((await client.threads())['nextCursor'], 'page2');
    expect(
      (await client.turns(
        't1',
        cursor: 'older',
      ))['data'][0]['items'][0]['text'],
      '你好',
    );
    expect(methods, [
      'initialize',
      'initialized',
      'account/read',
      'thread/list',
      'thread/turns/list',
    ]);
  });

  test(
    'correlates out-of-order replies and ignores unsolicited approvals',
    () async {
      final requests = <Map<String, dynamic>>[];
      final client = await fixture((req, ws) {
        requests.add(req);
        if (requests.length == 2) {
          ws.add(
            jsonEncode({
              'id': 999,
              'method': 'item/commandExecution/requestApproval',
              'params': {},
            }),
          );
          result(ws, requests[1], {'data': []});
          result(ws, requests[0], {'account': null});
        }
      });
      final results = await Future.wait([client.account(), client.threads()]);
      expect(results[0].containsKey('account'), isTrue);
      expect(results[1]['data'], isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests.length, 2);
    },
  );

  test(
    'remote errors expose code without server diagnostic contents',
    () async {
      final client = await fixture(
        (req, ws) => ws.add(
          jsonEncode({
            'id': req['id'],
            'error': {'code': -32000, 'message': 'secret-marker'},
          }),
        ),
      );
      await expectLater(
        client.account(),
        throwsA(
          isA<CodexRpcException>().having(
            (e) => e.message,
            'safe error',
            allOf(contains('-32000'), isNot(contains('secret-marker'))),
          ),
        ),
      );
    },
  );

  test('disconnect fails pending requests and rejects further calls', () async {
    final client = await fixture((req, ws) {
      unawaited(ws.close());
    });
    await expectLater(client.account(), throwsStateError);
    await client.done;
    await expectLater(client.threads(), throwsStateError);
  });

  test('rejects invalid handshake and closes transport', () async {
    final input = StreamController<List<int>>();
    var closed = false;
    final future = CodexClient.connect(
      input: input.stream,
      write: (_) {
        input.add(
          ascii.encode(
            'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: invalid\r\n\r\n',
          ),
        );
      },
      closeTransport: () {
        closed = true;
      },
    );
    await expectLater(future, throwsFormatException);
    expect(closed, isTrue);
    await input.close();
  });

  test('handshake has a timeout and cleans up', () async {
    final input = StreamController<List<int>>();
    var closed = false;
    await expectLater(
      CodexClient.connect(
        input: input.stream,
        write: (_) {},
        closeTransport: () {
          closed = true;
        },
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(closed, isTrue);
    await input.close();
  });

  test('shell paths cannot become shell code', () async {
    const path = "/tmp/a'b \$(touch should-not-exist); `echo injected`";
    final result = await Process.run('/bin/sh', [
      '-c',
      'printf %s ${shellQuote(path)}',
    ]);
    expect(result.stdout, path);
    expect(() => proxyCommand('codex', '/tmp/socket'), throwsFormatException);
    expect(
      () => proxyCommand('/bin/codex\nwhoami', '/tmp/socket'),
      throwsFormatException,
    );
  });
}
