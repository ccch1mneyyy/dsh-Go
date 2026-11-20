// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
/// Agent ACP（`agent.acp.*`）远程客户端。
///
/// Host 把 Claude Code 等 ACP agent 暴露为**顶层 RPC** `agent.acp.call`，
/// 而不是 `harness.remote.call` 的 gateway 端点。本类只依赖
/// [RemoteHostSession.rpc]，走顶层通道，和 `RemoteDshWeb` 同一层。
///
/// 重要：`claude:` 这类前缀只是客户端 UI 投影，Host 不按前缀路由。
/// 发给 ACP 的 sessionId 必须是 native id，见 [nativeAcpId]。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'carrier/tunnel_carrier.dart' show RemoteHostSession;
import 'channel/rpc_client.dart' show RemoteEvent;
import 'util/bytes.dart' show JsonMap, asInt, asMap, asString, concatBytes, uuidV7;

/// ACP 调用失败。
class RemoteAcpException implements Exception {
  const RemoteAcpException(this.code, [this.message = '']);

  final String code;
  final String message;

  @override
  String toString() => 'RemoteAcpException($code${message.isEmpty ? '' : ', $message'})';
}

/// 每次 `session/prompt` 最多阻塞 10 分钟（Host 侧 turn 时长）。
const Duration acpPromptTimeout = Duration(minutes: 10);

/// ACP transfer 分块大小（与 Host `AGENT_ACP_TRANSFER_CHUNK_BYTES` 一致）。
const int acpTransferChunkBytes = 512 * 1024;

/// ACP transfer 请求/响应上限（与 Host `MAX_AGENT_ACP_TRANSFER_BYTES` 一致）。
const int acpMaxTransferBytes = 288 * 1024 * 1024;

/// 可识别的 ACP 客户端前缀。
final RegExp _backendPrefix = RegExp(r'^(claude|cursor|pi|opencode|antigravity|hermes):');

/// 剥掉客户端 UI 前缀，返回发给 ACP 的 native session id。
String nativeAcpId(String sessionId) => sessionId.replaceFirst(_backendPrefix, '');

/// 从 sessionId 推断 ACP backend；没有可识别前缀时返回 null。
String? backendFromSessionId(String sessionId) {
  final match = _backendPrefix.firstMatch(sessionId);
  return match?.group(1);
}

/// 带前缀的展示用 id（UI 投影）。
String acpDisplayId(String backend, String nativeSessionId) => '$backend:$nativeSessionId';

/// Host 在 `harness.transport.describe` 里通告的 ACP workspace 类型。
class AcpWorkspaceType {
  const AcpWorkspaceType({required this.id, required this.name, required this.capability, required this.available});

  final String id;
  final String name;
  final String capability;
  final bool available;

  @override
  String toString() => 'AcpWorkspaceType($id, available: $available)';
}

/// 把 `workspaceTypes`（Object?）解析成 typed 列表；非法项忽略。
List<AcpWorkspaceType> parseAcpWorkspaceTypes(Object? value) {
  if (value is! List) return const <AcpWorkspaceType>[];
  final out = <AcpWorkspaceType>[];
  for (final item in value) {
    final map = asMap(item);
    if (map == null) continue;
    final id = asString(map['id']);
    final capability = asString(map['capability']);
    if (id == null || id.isEmpty || capability == null || capability.isEmpty) continue;
    final name = asString(map['name']) ?? id;
    out.add(AcpWorkspaceType(id: id, name: name, capability: capability, available: map['available'] == true));
  }
  return List.unmodifiable(out);
}

/// ACP 目录里的工作区。
class AcpWorkspace {
  const AcpWorkspace({required this.path, this.title, this.sessionCount});

  final String path;
  final String? title;
  final int? sessionCount;
}

/// ACP 目录里的会话（native id，不带前缀）。
class AcpSession {
  const AcpSession({required this.sessionId, this.title = '', this.createdAt, this.updatedAt, this.cwd});

  final String sessionId;
  final String title;
  final int? createdAt;
  final int? updatedAt;
  final String? cwd;
}

/// ACP 流式帧（`agent.acp.frame` data.frame）。
class AcpFrame {
  const AcpFrame({required this.streamId, required this.frame});

  final String streamId;
  final JsonMap frame;
}

/// 一个打开的 ACP 流。调用 [close] 释放 Host 侧资源。
class AcpStream {
  AcpStream(this._close);

  final Future<void> Function() _close;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _close();
  }
}

/// `agent.acp.*` 顶层 RPC 客户端。不重连、不重放。
class RemoteAcpClient {
  RemoteAcpClient(this.session);

  final RemoteHostSession session;

  /// Host 声明支持通用 ACP 域，且连接仍有效。
  bool get supported => !session.isClosed && session.capabilities.contains('agent.acp.v1');

  /// 某 backend 的 workspace 类型是否 available。
  bool backendAvailable(String backend) => parseAcpWorkspaceTypes(session.workspaceTypes)
      .any((type) => type.id == backend && type.available);

  /// 直接调 `agent.acp.call`。`session/prompt` 自动延长到 10 分钟。
  Future<Object?> call(String method, [Object? params]) async {
    if (!supported) {
      throw RemoteAcpException(session.isClosed ? 'CONNECTION_NOT_FOUND' : 'ACP_NOT_SUPPORTED');
    }
    return session.rpc.call(
      'agent.acp.call',
      {'method': method, 'params': params ?? const <String, Object?>{}},
      timeout: method == 'session/prompt' ? acpPromptTimeout : null,
    );
  }

  /// 回一个权限请求（allow-once / reject-once / cancel）。
  Future<Object?> respond(String requestHandle, String decision) async {
    if (requestHandle.isEmpty) throw const RemoteAcpException('INVALID_REQUEST_HANDLE');
    if (decision != 'allow-once' && decision != 'reject-once' && decision != 'cancel') {
      throw const RemoteAcpException('INVALID_DECISION');
    }
    return session.rpc.call('agent.acp.respond', {'requestHandle': requestHandle, 'decision': decision});
  }

  /// 大请求/大响应走 transfer 分块通道。标准 base64（与 Host 一致）。
  Future<Object?> transferCall(String method, JsonMap params, {Duration? timeout}) async {
    final requestBytes = utf8.encode(jsonEncode({'method': method, 'params': params}));
    if (requestBytes.isEmpty || requestBytes.length > acpMaxTransferBytes) {
      throw const RemoteAcpException('REQUEST_TOO_LARGE');
    }
    final transferId = uuidV7();
    final totalChunks = (requestBytes.length + acpTransferChunkBytes - 1) ~/ acpTransferChunkBytes;
    try {
      await session.rpc.call('agent.acp.transfer.open', {
        'transferId': transferId,
        'totalBytes': requestBytes.length,
        'totalChunks': totalChunks,
      });
      for (var index = 0; index < totalChunks; index++) {
        final start = index * acpTransferChunkBytes;
        final end = start + acpTransferChunkBytes < requestBytes.length
            ? start + acpTransferChunkBytes
            : requestBytes.length;
        await session.rpc.call('agent.acp.transfer.chunk', {
          'transferId': transferId,
          'index': index,
          'data': base64Encode(requestBytes.sublist(start, end)),
        });
      }
      final commit = asMap(await session.rpc.call(
        'agent.acp.transfer.commit',
        {'transferId': transferId},
        timeout: timeout ?? (method == 'session/prompt' ? acpPromptTimeout : null),
      ));
      if (commit == null) throw const RemoteAcpException('INVALID_TRANSFER_RESPONSE');
      if (commit['kind'] == 'inline') return commit['response'];
      if (commit['kind'] != 'chunked' || commit['transferId'] != transferId) {
        throw const RemoteAcpException('INVALID_TRANSFER_RESPONSE');
      }
      final totalBytes = asInt(commit['totalBytes']);
      final responseChunks = asInt(commit['totalChunks']);
      if (totalBytes == null ||
          totalBytes < 1 ||
          totalBytes > acpMaxTransferBytes ||
          responseChunks == null ||
          responseChunks != (totalBytes + acpTransferChunkBytes - 1) ~/ acpTransferChunkBytes) {
        throw const RemoteAcpException('INVALID_TRANSFER_RESPONSE');
      }
      final parts = <List<int>>[];
      for (var index = 0; index < responseChunks; index++) {
        final part = asMap(await session.rpc.call('agent.acp.transfer.read', {
          'transferId': transferId,
          'index': index,
        }));
        if (part == null || part['transferId'] != transferId || asInt(part['index']) != index) {
          throw const RemoteAcpException('INVALID_TRANSFER_RESPONSE');
        }
        final data = asString(part['data']);
        if (data == null) throw const RemoteAcpException('INVALID_TRANSFER_RESPONSE');
        final Uint8List decoded;
        try {
          decoded = base64Decode(data);
        } on FormatException {
          throw const RemoteAcpException('INVALID_TRANSFER_RESPONSE');
        }
        final expected = (index + 1) * acpTransferChunkBytes < totalBytes
            ? acpTransferChunkBytes
            : totalBytes - index * acpTransferChunkBytes;
        if (decoded.length != expected || base64Encode(decoded) != data) {
          throw const RemoteAcpException('INVALID_TRANSFER_RESPONSE');
        }
        parts.add(decoded);
      }
      final bytes = concatBytes(parts);
      try {
        return jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const RemoteAcpException('INVALID_TRANSFER_RESPONSE');
      }
    } finally {
      try {
        await session.rpc.call('agent.acp.transfer.close', {'transferId': transferId});
      } on Object {
        // 尽力清理；Host 也会在连接关闭/空闲时释放 handle。
      }
    }
  }

  /// 打开 ACP 流。事件订阅在 RPC 之前（broadcast sync）。
  Future<AcpStream> openStream(
    String sessionId,
    void Function(AcpFrame frame) onFrame, {
    void Function(Object? data)? onClosed,
  }) async {
    final native = nativeAcpId(sessionId);
    final streamId = uuidV7();
    StreamSubscription<RemoteEvent>? sub;
    var closed = false;

    void markClosed() {
      if (closed) return;
      closed = true;
      sub?.cancel();
    }

    sub = session.rpc.events.listen((event) {
      if (event.event == 'agent.acp.stream.closed') {
        final data = asMap(event.data);
        if (data != null && data['streamId'] == streamId) {
          markClosed();
          onClosed?.call(event.data);
        }
        return;
      }
      if (event.event != 'agent.acp.frame') return;
      final data = asMap(event.data);
      if (data == null) return;
      if (data['streamId'] != streamId && data['streamId'] != 'session:$native') return;
      final frame = asMap(data['frame']);
      if (frame == null) return;
      onFrame(AcpFrame(streamId: asString(data['streamId']) ?? streamId, frame: frame));
    });

    try {
      await session.rpc.call('agent.acp.stream.open', {'streamId': streamId, 'sessionId': native});
    } on Object {
      markClosed();
      rethrow;
    }
    return AcpStream(() async {
      markClosed();
      try {
        await session.rpc.call('agent.acp.stream.close', {'streamId': streamId});
      } on Object {
        // 尽力清理。
      }
    });
  }

  /// 列出 ACP 工作区目录。
  Future<List<AcpWorkspace>> listWorkspaces(String backend) async {
    final result = await call('dsh/workspaceList', {'backend': backend});
    if (result is! List) throw const RemoteAcpException('INVALID_CATALOG');
    final out = <AcpWorkspace>[];
    for (final item in result) {
      final map = asMap(item);
      if (map == null) continue;
      final path = asString(map['path']);
      if (path == null || path.isEmpty) continue;
      out.add(AcpWorkspace(path: path, title: asString(map['title']), sessionCount: asInt(map['sessionCount'])));
    }
    return List.unmodifiable(out);
  }

  /// 列出某工作区下的 ACP 会话（返回 native id）。
  Future<List<AcpSession>> listSessions(String path, String backend, {int? limit}) async {
    final params = <String, Object?>{'path': path, 'backend': backend};
    if (limit != null) params['limit'] = limit;
    final result = asMap(await call('dsh/sessionList', params));
    if (result == null) throw const RemoteAcpException('INVALID_CATALOG');
    final items = result['items'];
    if (items is! List) throw const RemoteAcpException('INVALID_CATALOG');
    final out = <AcpSession>[];
    for (final item in items) {
      final map = asMap(item);
      if (map == null) continue;
      final id = asString(map['conversationId']);
      if (id == null || id.isEmpty) continue;
      out.add(AcpSession(
        sessionId: id,
        title: asString(map['title']) ?? '',
        createdAt: asInt(map['createdAt']),
        updatedAt: asInt(map['updatedAt']),
        cwd: asString(map['cwd']),
      ));
    }
    return List.unmodifiable(out);
  }

  /// 读取 ACP 会话历史（走 transfer，返回原始 events）。[sessionId] 为 native id。
  Future<List<Object?>> loadSessionHistory(String sessionId, String backend) async {
    final result = asMap(await transferCall('dsh/sessionHistory', {
      'sessionId': nativeAcpId(sessionId),
      'backend': backend,
    }));
    if (result == null) throw const RemoteAcpException('INVALID_HISTORY');
    final events = result['events'];
    if (events is! List) throw const RemoteAcpException('INVALID_HISTORY');
    return List.unmodifiable(events);
  }

  /// 新建 ACP 会话，返回 native sessionId。
  Future<AcpSession> createSession(String cwd, String backend) async {
    final result = asMap(await call('session/new', {'cwd': cwd, 'backend': backend, 'mcpServers': const <Object?>[]}));
    if (result == null) throw const RemoteAcpException('INVALID_RESPONSE');
    final id = asString(result['sessionId']);
    if (id == null || id.isEmpty) throw const RemoteAcpException('INVALID_RESPONSE');
    return AcpSession(sessionId: id, cwd: cwd);
  }

  /// 发送文本 prompt。阻塞到本轮结束；增量经 [openStream]。
  Future<Object?> prompt(String sessionId, String text, String backend) {
    return call('session/prompt', {
      'sessionId': nativeAcpId(sessionId),
      'backend': backend,
      'prompt': [{'type': 'text', 'text': text}],
    });
  }

  /// 中断当前 turn。
  Future<Object?> cancel(String sessionId) => call('session/cancel', {'sessionId': nativeAcpId(sessionId)});

  /// ACP initialize 握手。
  Future<Object?> initialize() => call('initialize', {
    'protocolVersion': 1,
    'clientInfo': {'name': 'dsh-go', 'version': '1'},
  });
}
