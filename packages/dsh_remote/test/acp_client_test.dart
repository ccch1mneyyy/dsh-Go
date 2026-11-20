import 'dart:async';
import 'dart:convert';

import 'package:dsh_remote/dsh_remote.dart' show RemoteHostSession, RemoteRpcClient, RemoteRpcException, SecureChannelClosed;
import 'package:dsh_remote/src/acp_client.dart';
import 'package:dsh_remote/src/channel/rpc_client.dart' show RemoteEvent;
import 'package:test/test.dart';

Matcher _code(String code) => isA<RemoteAcpException>().having((error) => error.code, 'code', code);

class _Rpc implements RemoteRpcClient {
  final calls = <({String method, Object? params, Duration? timeout})>[];
  final eventsController = StreamController<RemoteEvent>.broadcast(sync: true);
  FutureOr<Object?> Function(String method, Object? params)? handler;
  final _done = Completer<SecureChannelClosed>();

  @override
  bool get isClosed => _done.isCompleted;
  @override
  Future<SecureChannelClosed> get done => _done.future;
  @override
  Stream<RemoteEvent> get events => eventsController.stream;
  @override
  Future<Object?> call(String method, Object? params, {Duration? timeout}) async {
    calls.add((method: method, params: params, timeout: timeout));
    if (handler != null) return await handler!(method, params);
    return switch (method) {
      'agent.acp.stream.close' => {'closed': true},
      'agent.acp.transfer.close' => {'closed': true},
      _ => <String, Object?>{},
    };
  }
  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete(const SecureChannelClosed('CLIENT_CLOSED', 'test'));
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Rpc rpc;
  late RemoteAcpClient acp;

  setUp(() {
    rpc = _Rpc();
    final session = RemoteHostSession(
      rpc: rpc,
      capabilities: const ['agent.acp.v1'],
      workspaceTypes: const [
        {'id': 'claude', 'name': 'Claude', 'capability': 'agent.acp.claude.v1', 'available': true},
        {'id': 'pi', 'name': 'Pi', 'capability': 'agent.acp.pi.v1', 'available': false},
      ],
    );
    acp = RemoteAcpClient(session);
  });

  group('id 前缀投影', () {
    test('nativeAcpId 剥掉后端前缀', () {
      expect(nativeAcpId('claude:abc-123'), 'abc-123');
      expect(nativeAcpId('cursor:xyz'), 'xyz');
      expect(nativeAcpId('plain-id'), 'plain-id');
    });
    test('backendFromSessionId 推断后端', () {
      expect(backendFromSessionId('claude:abc'), 'claude');
      expect(backendFromSessionId('plain-id'), isNull);
    });
    test('acpDisplayId 生成展示 id', () {
      expect(acpDisplayId('claude', 'abc'), 'claude:abc');
    });
  });

  group('能力探测', () {
    test('supported 需 agent.acp.v1 且连接有效', () {
      expect(acp.supported, isTrue);
      expect(acp.backendAvailable('claude'), isTrue);
      expect(acp.backendAvailable('pi'), isFalse);
      expect(acp.backendAvailable('unknown'), isFalse);
    });
    test('无能力或断开时 call 直接拒绝', () async {
      final old = RemoteAcpClient(RemoteHostSession(rpc: rpc, capabilities: const []));
      expect(old.supported, isFalse);
      await expectLater(old.call('initialize'), throwsA(_code('ACP_NOT_SUPPORTED')));
      await rpc.close();
      expect(acp.supported, isFalse);
      await expectLater(acp.call('initialize'), throwsA(_code('CONNECTION_NOT_FOUND')));
      expect(rpc.calls, isEmpty);
    });
  });

  group('workspaceTypes 解析', () {
    test('typed 解析并忽略非法项', () {
      final types = parseAcpWorkspaceTypes([
        {'id': 'claude', 'capability': 'agent.acp.claude.v1', 'available': true},
        {'id': 'bad'},
        'not a map',
      ]);
      expect(types, hasLength(1));
      expect(types.single.id, 'claude');
      expect(types.single.name, 'claude');
      expect(types.single.available, isTrue);
    });
  });

  group('call / prompt / respond', () {
    test('call 打包 method+params 为 agent.acp.call', () async {
      rpc.handler = (method, params) => {'ok': true};
      final result = await acp.initialize();
      expect(result, {'ok': true});
      expect(rpc.calls.single.method, 'agent.acp.call');
      final acpParams = rpc.calls.single.params as Map<String, Object?>;
      expect(acpParams['method'], 'initialize');
      expect(acpParams['params'], isA<Map<String, Object?>>());
    });

    test('session/prompt 用 native id 且延长到 10 分钟', () async {
      rpc.handler = (method, params) => {'stopReason': 'end_turn'};
      await acp.prompt('claude:native-123', '你好', 'claude');
      expect(rpc.calls.single.timeout, const Duration(minutes: 10));
      final call = rpc.calls.single.params as Map<String, Object?>;
      expect(call['method'], 'session/prompt');
      final p = call['params'] as Map<String, Object?>;
      expect(p['sessionId'], 'native-123');
      expect(p['backend'], 'claude');
      expect(p['prompt'], [
        {'type': 'text', 'text': '你好'}
      ]);
    });

    test('respond 校验 requestHandle 与 decision', () async {
      await expectLater(acp.respond('', 'allow-once'), throwsA(_code('INVALID_REQUEST_HANDLE')));
      await expectLater(acp.respond('h', 'maybe'), throwsA(_code('INVALID_DECISION')));
      await acp.respond('handle-1', 'allow-once');
      expect(rpc.calls.single.method, 'agent.acp.respond');
      expect(rpc.calls.single.params, {'requestHandle': 'handle-1', 'decision': 'allow-once'});
    });
  });

  group('catalog', () {
    test('listWorkspaces 解析目录', () async {
      rpc.handler = (method, params) => [
        {'path': 'E:\\Ai-Project\\Claude', 'title': 'Claude', 'sessionCount': 2},
        {'title': 'no path'},
      ];
      final workspaces = await acp.listWorkspaces('claude');
      expect(workspaces, hasLength(1));
      expect(workspaces.single.path, 'E:\\Ai-Project\\Claude');
      expect(workspaces.single.sessionCount, 2);
      expect((rpc.calls.single.params as Map)['params'], {'backend': 'claude'});
    });

    test('listSessions 解析 native id 会话', () async {
      rpc.handler = (method, params) => {
        'items': [
          {'conversationId': 'native-1', 'title': '问候', 'updatedAt': 1234567890},
        ],
      };
      final sessions = await acp.listSessions('E:\\Ai-Project\\Claude', 'claude', limit: 50);
      expect(sessions, hasLength(1));
      expect(sessions.single.sessionId, 'native-1');
      expect(sessions.single.title, '问候');
      final p = (rpc.calls.single.params as Map)['params'] as Map;
      expect(p['backend'], 'claude');
      expect(p['limit'], 50);
    });
  });

  group('transferCall', () {
    test('inline 响应直接返回 JSON', () async {
      rpc.handler = (method, params) {
        if (method == 'agent.acp.transfer.commit') {
          return {'kind': 'inline', 'response': {'events': [{'type': 'user'}]}};
        }
        return {};
      };
      final result = await acp.loadSessionHistory('claude:native-1', 'claude');
      expect(result, hasLength(1));
      final methods = rpc.calls.map((c) => c.method).toList();
      expect(methods, contains('agent.acp.transfer.open'));
      expect(methods, contains('agent.acp.transfer.chunk'));
      expect(methods, contains('agent.acp.transfer.commit'));
      expect(methods.last, 'agent.acp.transfer.close');
      // 请求体用标准 base64，method+params 打包。
      final chunkCall = rpc.calls.firstWhere((c) => c.method == 'agent.acp.transfer.chunk');
      final data = (chunkCall.params as Map)['data'] as String;
      final decoded = jsonDecode(utf8.decode(base64Decode(data))) as Map<String, Object?>;
      expect(decoded['method'], 'dsh/sessionHistory');
      final params = decoded['params'] as Map<String, Object?>;
      expect(params['sessionId'], 'native-1'); // 前缀已剥
      expect(params['backend'], 'claude');
    });

    test('chunked 响应逐块读取并校验', () async {
      final payload = utf8.encode(jsonEncode({'events': [{'type': 'assistant', 'text': 'hi'}]}));
      final encoded = base64Encode(payload);
      rpc.handler = (method, params) {
        if (method == 'agent.acp.transfer.commit') {
          return {'kind': 'chunked', 'transferId': (params as Map)['transferId'], 'totalBytes': payload.length, 'totalChunks': 1};
        }
        if (method == 'agent.acp.transfer.read') {
          return {'transferId': (params as Map)['transferId'], 'index': 0, 'data': encoded};
        }
        return {};
      };
      final result = await acp.loadSessionHistory('native-2', 'claude');
      expect((result.single as Map)['text'], 'hi');
      expect(rpc.calls.map((c) => c.method), contains('agent.acp.transfer.read'));
    });

    test('chunked descriptor 非法时抛错', () async {
      rpc.handler = (method, params) {
        if (method == 'agent.acp.transfer.commit') {
          return {'kind': 'chunked', 'transferId': 'different', 'totalBytes': 10, 'totalChunks': 1};
        }
        return {};
      };
      await expectLater(
        acp.loadSessionHistory('native', 'claude'),
        throwsA(_code('INVALID_TRANSFER_RESPONSE')),
      );
    });
  });

  group('stream', () {
    test('openStream 先订阅再开流，按 streamId 收帧', () async {
      final frames = <AcpFrame>[];
      final stream = await acp.openStream('claude:session-9', frames.add);
      final openCall = rpc.calls.firstWhere((c) => c.method == 'agent.acp.stream.open');
      final params = openCall.params as Map<String, Object?>;
      final streamId = params['streamId'] as String;
      expect(params['sessionId'], 'session-9');
      rpc.eventsController.add(RemoteEvent('agent.acp.frame', {
        'streamId': streamId,
        'frame': {'method': 'session/update', 'params': {'update': {'type': 'agent_message_chunk'}}},
      }));
      expect(frames, hasLength(1));
      expect(frames.single.frame['method'], 'session/update');
      await stream.close();
      expect(rpc.calls.last.method, 'agent.acp.stream.close');
    });

    test('openStream 失败时清理订阅', () async {
      rpc.handler = (method, params) {
        if (method == 'agent.acp.stream.open') throw RemoteRpcException('RPC_TIMEOUT', 'test');
        return {};
      };
      await expectLater(
        acp.openStream('session-1', (_) {}),
        throwsA(isA<RemoteRpcException>()),
      );
    });
  });
}
