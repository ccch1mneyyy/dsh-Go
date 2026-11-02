import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_client/src/background_json.dart';
import 'package:test/test.dart';

void main() {
  test('small streaming JSON stays synchronous', () {
    final decoded = decodeJsonText('{"text":"你好🌊","index":1}');
    expect(decoded, isNot(isA<Future<Object?>>()));
    expect(decoded, {'text': '你好🌊', 'index': 1});
    expect(decodeJsonText('not json'), isNull);
  });

  test('large JSON transfers the complete graph without blocking the event loop', () async {
    final value = {
      'text': '鲸鱼🌊' * backgroundJsonThreshold,
      'records': List.generate(1000, (i) => {'seq': i}),
    };
    final text = jsonEncode(value);
    var timerRan = false;
    final tick = Completer<void>();
    Timer.run(() {
      timerRan = true;
      tick.complete();
    });
    final decoded = decodeJsonText(text);
    expect(decoded, isA<Future<Object?>>());
    expect(await decoded, value);
    expect(timerRan, isTrue);
    await tick.future;
  });

  test('large malformed JSON retains the tolerant reader contract', () async {
    expect(await decodeJsonText(' ' * backgroundJsonThreshold), isNull);
  });

  test('HTTP bytes decode UTF-8 off-isolate with the same malformed-byte policy', () async {
    final value = {'text': '你好🌊' * backgroundJsonThreshold};
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    final decoded = decodeJsonBytes(bytes);
    expect(decoded, isA<Future<Object?>>());
    expect(await decoded, value);
    expect(decodeJsonBytes(Uint8List.fromList(utf8.encode('[1,true,null]'))), [1, true, null]);
    final malformed = Uint8List.fromList([...utf8.encode('"${'a' * backgroundJsonThreshold}'), 0xff, 0x22]);
    expect(await decodeJsonBytes(malformed), '${'a' * backgroundJsonThreshold}\uFFFD');
    expect(await decodeJsonBytes(Uint8List(backgroundJsonThreshold)), isNull);
  });

  group('real WebSocket mux', () {
    late HttpServer server;
    late DshHttpCarrier carrier;
    late WebSocket peer;
    late DshMuxLink link;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final connected = Completer<WebSocket>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {});
        connected.complete(socket);
      });
      carrier = DshHttpCarrier(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
      link = await carrier.openLink(const MuxOptions());
      peer = await connected.future;
    });

    tearDown(() async {
      await link.close(1000, 'test done');
      await peer.close();
      await carrier.close();
      await server.close(force: true);
    });

    test('a small token and end cannot overtake a large snapshot', () async {
      final frames = <Map<String, Object?>>[];
      final completed = Completer<void>();
      link.start(
        onFrame: (frame) {
          frames.add(frame);
          if (frames.length == 3) completed.complete();
        },
        onLost: (failure, cause) => completed.completeError(failure),
      );
      final text = '鲸🌊' * backgroundJsonThreshold;
      peer
        ..add(
          jsonEncode({
            'type': 'item',
            'streamId': 's',
            'value': {'snapshot': text},
          }),
        )
        ..add(
          jsonEncode({
            'type': 'item',
            'streamId': 's',
            'value': {'token': 'next'},
          }),
        )
        ..add(jsonEncode({'type': 'end', 'streamId': 's'}));
      await completed.future.timeout(const Duration(seconds: 5));
      expect(frames.map((f) => f['type']), ['item', 'item', 'end']);
      expect(frames.first['value'], {'snapshot': text});
      expect(frames[1]['value'], {'token': 'next'});
    });

    test('closing a link prevents delivery of queued background decodes', () async {
      final frames = <Map<String, Object?>>[];
      var lost = false;
      link.start(onFrame: frames.add, onLost: (_, _) => lost = true);
      peer
        ..add(jsonEncode({'type': 'item', 'streamId': 's', 'value': 'x' * (backgroundJsonThreshold * 16)}))
        ..add(jsonEncode({'type': 'end', 'streamId': 's'}));
      await link.close(1000, 'retired generation');
      final countAtClose = frames.length;
      // Drain both the physical socket and worker completion. Nothing from
      // this link may be published into a replacement mux after close.
      await peer.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(frames, hasLength(countAtClose));
      expect(lost, isFalse);
    });

    for (final message in <Object>[
      'not json',
      ' ' * backgroundJsonThreshold,
      [1, 2, 3],
    ]) {
      test('invalid ${message is String ? '${message.length}-character text' : 'binary'} frame fails once', () async {
        final failed = Completer<Object?>();
        var losses = 0;
        link.start(
          onFrame: (_) => fail('invalid frame delivered'),
          onLost: (_, cause) {
            losses++;
            failed.complete(cause);
          },
        );
        peer.add(message);
        expect(await failed.future.timeout(const Duration(seconds: 5)), isA<DshProtocolException>());
        await peer.close();
        expect(losses, 1);
      });
    }
  });

  test('large HTTP RPC responses preserve the envelope and Unicode values', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final carrier = DshHttpCarrier(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    addTearDown(() async {
      await carrier.close();
      await server.close(force: true);
    });
    final value = {'text': '鲸🌊' * backgroundJsonThreshold};
    server.listen((request) async {
      final envelope = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {'ok': true, 'value': value},
          }),
        );
      await request.response.close();
    });
    final result = await carrier.call('session/history', const {});
    expect(result, isA<RpcOk>());
    expect((result as RpcOk).value, value);
  });
}
