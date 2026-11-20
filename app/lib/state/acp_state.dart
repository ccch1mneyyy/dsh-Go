// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
/// ACP（Claude Code 等）会话在 app 状态层的接入点。
///
/// Host 通过 `agent.acp.*` 顶层 RPC 暴露 ACP agent；这些会话不在标准
/// `session/list` 注册表里，所以要在会话列表里额外合并一份投影。
/// id 用 `claude:` 前缀标记为 ACP 行，Host 调用前由 [nativeAcpId] 剥掉。
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show SessionProjections, SessionSummary;
import 'package:dsh_remote/dsh_remote.dart'
    show AcpSession, DshConnectionState, RemoteAcpClient, RemoteHostSession, RemoteTunnelCarrier;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart' show HostConnection;
import 'read_list_identity.dart' show readListLiveConnectionProvider;

/// 从当前实时连接拿 ACP 客户端；连接不支持 ACP 时返回 null。
RemoteAcpClient? acpClientFor(HostConnection? connection) {
  final carrier = connection?.client.carrier;
  if (carrier is! RemoteTunnelCarrier) return null;
  final session = carrier.session;
  if (session == null || session.isClosed) return null;
  final client = RemoteAcpClient(session);
  return client.supported ? client : null;
}

/// 观察 ACP 会话所用的 Host session（照抄 remoteWebSessionProvider 的接缝：
/// Noise session 换掉时重新采样，而不是用 carrier 缓存的能力表）。
final acpSessionProvider = StreamProvider.autoDispose<RemoteHostSession?>((ref) {
  final connection = ref.watch(readListLiveConnectionProvider);
  final carrier = connection?.client.carrier;
  if (carrier is! RemoteTunnelCarrier) return Stream.value(null);
  return Stream.multi((output) {
    var cancelled = false;
    RemoteHostSession? observed;
    void sample() {
      if (cancelled) return;
      final session = carrier.session;
      if (!identical(observed, session)) {
        observed = session;
        if (session != null) {
          unawaited(
            session.rpc.done.then((_) {
              if (!cancelled && identical(observed, session)) sample();
            }),
          );
        }
      }
      final connected = carrier.state?.isConnected ?? connection!.client.mux.state == DshConnectionState.connected;
      final supported = session != null && !session.isClosed && RemoteAcpClient(session).supported;
      output.addSync(connected && supported ? session : null);
    }

    final sessions = carrier.sessions.listen((_) => sample());
    final states = carrier.states.listen((_) => sample());
    sample();
    output.onCancel = () async {
      cancelled = true;
      await sessions.cancel();
      await states.cancel();
    };
  });
});

/// 把一个 ACP 会话映射成 app 列表用的 [SessionSummary]。
///
/// 关键：`origin='claude'`（不能是 'subagent'，否则会被顶层列表过滤），
/// `projectionsKind='sequenced'`（跳过逐行标题回填），标题直接塞进
/// projections。`copyWith` 不能改 sessionId/origin/raw，所以构造时一次给全。
SessionSummary _toSummary(AcpSession s) {
  final title = s.title.trim();
  return SessionSummary(
    sessionId: 'claude:${s.sessionId}',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(s.updatedAt ?? 0),
    running: false,
    blank: false,
    agentAvailable: true,
    cwd: s.cwd,
    origin: 'claude',
    projections: SessionProjections(-1, <String, Object?>{'title': title}),
    projectionsKind: 'sequenced',
    raw: const <String, Object?>{'backend': 'claude'},
  );
}

/// Claude backend 下所有工作区的会话，映射为可合并进会话列表的投影。
/// ACP 不可用或未登录时静默返回空列表，不影响标准会话。
final acpClaudeSessionsProvider = FutureProvider.autoDispose<List<SessionSummary>>((ref) async {
  final connection = ref.watch(readListLiveConnectionProvider);
  final acp = acpClientFor(connection);
  if (acp == null || !acp.backendAvailable('claude')) return const <SessionSummary>[];
  try {
    final workspaces = await acp.listWorkspaces('claude');
    final out = <SessionSummary>[];
    final seen = <String>{};
    for (final ws in workspaces) {
      final sessions = await acp.listSessions(ws.path, 'claude');
      for (final s in sessions) {
        final id = 'claude:${s.sessionId}';
        if (!seen.add(id)) continue;
        out.add(_toSummary(s));
      }
    }
    return List.unmodifiable(out);
  } on Object {
    // ACP 未登录 / 目录不可读：降级为空，不阻断标准会话列表。
    return const <SessionSummary>[];
  }
});
