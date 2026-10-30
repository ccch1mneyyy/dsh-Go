import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';

import 'src/vendor/web_socket_channel/channel.dart';

/// HTTP upgrade + WebSocket over raw `codex app-server proxy` bytes.
/// Does not open a TCP listener, spawn a daemon, or manage account credentials.
class CodexRpcException implements Exception {
  const CodexRpcException(this.code, this.message);
  final Object? code;
  final String message;
  @override
  String toString() => 'Codex ($code): $message';
}

abstract class CodexRpc {
  Stream<Map<String, dynamic>> get messages;
  Future<void> get done;
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  );
  void respond(Object id, {Map<String, dynamic>? result, String? error});
  Future<void> close();
}

class CodexClient implements CodexRpc {
  CodexClient._(this._channel, this._disposeTransport) {
    _messages = _channel.stream.listen(
      _receive,
      onError: (Object e) => _fail(e),
      onDone: () => _fail(StateError('连接已关闭')),
    );
  }

  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get messages => _events.stream;
  @override
  void respond(Object id, {Map<String, dynamic>? result, String? error}) {
    if (_closed) throw StateError('连接已关闭');
    _channel.sink.add(
      jsonEncode({
        'id': id,
        if (error == null) 'result': result ?? {},
        if (error != null) 'error': {'code': -32601, 'message': error},
      }),
    );
  }

  final WebSocketChannel _channel;
  final Future<void> Function() _disposeTransport;
  late final StreamSubscription<dynamic> _messages;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final _done = Completer<void>();
  int _id = 0;
  bool _closed = false;
  Future<void> get done => _done.future;

  static Future<CodexClient> connect({
    required Stream<List<int>> input,
    required void Function(List<int>) write,
    required void Function() closeTransport,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final incoming = StreamController<List<int>>();
    final outgoing = StreamController<List<int>>();
    final handshake = Completer<void>();
    final key = base64Encode(
      List.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final headers = <int>[];
    var upgraded = false;
    var disposed = false;
    late StreamSubscription<List<int>> subscription;
    final writes = outgoing.stream.listen(
      (bytes) {
        if (disposed) return;
        try {
          write(bytes);
        } catch (e, st) {
          if (!handshake.isCompleted) {
            handshake.completeError(e, st);
          } else if (!incoming.isClosed) {
            incoming.addError(e, st);
          }
        }
      },
      onError: (Object _) => closeTransport(),
      onDone: closeTransport,
    );
    subscription = input.listen(
      (chunk) {
        if (upgraded) {
          // dartssh2 returns subviews with a non-zero byteOffset. The legacy
          // stream WebSocket decoder indexes the backing buffer from zero.
          incoming.add(Uint8List.fromList(chunk));
          return;
        }
        headers.addAll(chunk);
        var end = -1;
        for (var i = 0; i + 3 < headers.length; i++) {
          if (headers[i] == 13 &&
              headers[i + 1] == 10 &&
              headers[i + 2] == 13 &&
              headers[i + 3] == 10) {
            end = i + 4;
            break;
          }
        }
        if (end == -1 && headers.length <= 16384) return;
        try {
          if (end == -1 || end > 16384) throw const FormatException('升级响应过大');
          final lines = ascii.decode(headers.sublist(0, end)).split('\r\n');
          final fields = <String, String>{};
          for (final line in lines.skip(1).where((s) => s.contains(':'))) {
            final colon = line.indexOf(':');
            fields[line.substring(0, colon).toLowerCase()] = line
                .substring(colon + 1)
                .trim();
          }
          if (!RegExp(r'^HTTP/1\.[01] 101(?: |$)').hasMatch(lines.first) ||
              fields['upgrade']?.toLowerCase() != 'websocket' ||
              !(fields['connection']
                      ?.toLowerCase()
                      .split(',')
                      .map((s) => s.trim())
                      .contains('upgrade') ??
                  false) ||
              fields['sec-websocket-accept'] != WebSocketChannel.signKey(key)) {
            throw const FormatException('不是有效的 Codex WebSocket 升级响应');
          }
          upgraded = true;
          if (headers.length > end) incoming.add(headers.sublist(end));
          headers.clear();
          handshake.complete();
        } catch (e, st) {
          if (!handshake.isCompleted) handshake.completeError(e, st);
        }
      },
      onError: (Object e, StackTrace st) {
        if (!handshake.isCompleted) {
          handshake.completeError(e, st);
        } else if (upgraded) {
          incoming.addError(e, st);
        }
      },
      onDone: () {
        if (!handshake.isCompleted)
          handshake.completeError(StateError('代理在握手前退出'));
        unawaited(incoming.close());
      },
    );
    Future<void> dispose() async {
      if (disposed) return;
      disposed = true;
      await writes.cancel();
      closeTransport();
      await subscription.cancel();
      unawaited(incoming.close());
      unawaited(outgoing.close());
    }

    try {
      write(
        ascii.encode(
          'GET / HTTP/1.1\r\nHost: localhost\r\n'
          'Upgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: $key\r\n\r\n',
        ),
      );
      await handshake.future.timeout(timeout);
      final ws = WebSocketChannel(
        StreamChannel(incoming.stream, outgoing.sink),
        serverSide: false,
      );
      return CodexClient._(ws, dispose);
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  void _receive(dynamic payload) {
    try {
      if (payload is! String || payload.length > 16 * 1024 * 1024) {
        throw const FormatException('无效或过大的协议消息');
      }
      final message = jsonDecode(payload) as Map<String, dynamic>;
      // Subscribers decide which joined-thread requests they can handle.
      if (message.containsKey('method')) {
        _events.add(message);
        return;
      }
      final pending = _pending[message['id']];
      if (pending == null) return;
      if (message.containsKey('error')) {
        pending.completeError(
          CodexRpcException(
            (message['error'] as Map)['code'],
            "服务器拒绝请求（${(message['error'] as Map)['code']}）",
          ),
        );
      } else {
        if (!message.containsKey('result'))
          throw const FormatException('RPC 响应缺少 result');
        pending.complete(
          message['result'] == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(message['result'] as Map),
        );
      }
      _pending.remove(message['id']);
    } catch (e) {
      _fail(e);
      unawaited(_disposeTransport());
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    for (final request in _pending.values) {
      request.completeError(error);
    }
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
    unawaited(_events.close());
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_closed) throw StateError('连接已关闭，请重新连接');
    final id = ++_id;
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    try {
      _channel.sink.add(
        jsonEncode({'id': id, 'method': method, 'params': params}),
      );
      return await result.future.timeout(const Duration(seconds: 25));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> initialize() async {
    await request('initialize', {
      'clientInfo': {
        'name': 'dsh_go_codex',
        'title': 'DSH Go Codex',
        'version': '0.0.1',
      },
    });
    _channel.sink.add(jsonEncode({'method': 'initialized'}));
  }

  Future<Map<String, dynamic>> account() =>
      request('account/read', {'refreshToken': false});
  Future<Map<String, dynamic>> threads({String? cursor}) => request(
    'thread/list',
    {'limit': 20, 'useStateDbOnly': true, if (cursor != null) 'cursor': cursor},
  );
  Future<Map<String, dynamic>> turns(String threadId, {String? cursor}) =>
      request('thread/turns/list', {
        'threadId': threadId,
        'limit': 10,
        'sortDirection': 'desc',
        'itemsView': 'full',
        if (cursor != null) 'cursor': cursor,
      });

  Future<void> close() async {
    _fail(StateError('已断开连接'));
    unawaited(_channel.sink.close(1000).catchError((Object _) {}));
    await _messages.cancel();
    await _disposeTransport();
  }
}

/// Quote a single shell argument; paths entered in the app are never code.
String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String proxyCommand(String binary, String socket) {
  for (final path in [binary, socket]) {
    if (!path.startsWith('/') ||
        path.contains('\u0000') ||
        path.contains('\n')) {
      throw const FormatException('Codex 和 socket 路径必须是绝对路径');
    }
  }
  return '${shellQuote(binary)} app-server proxy --sock ${shellQuote(socket)}';
}
