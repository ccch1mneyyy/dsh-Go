/// 飞牛 fnconnect 主机：fnconnect ID / DSH 网关路径，以及登录一次得到的
/// 飞牛会话。
///
/// 与 SSH / 中继主机不同，飞牛的凭据是 **网页登录后的会话 Cookie**：登录在
/// WebView 里完成（见 `fnos_webview.dart`），Cookie 只存在安全存储里。之后
/// 每次连接把它作为 `Cookie` 头交给飞牛统一网关，由网关注入 DSH 自己的会话。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fnos/fnconnect.dart';
import '../fnos/fnos_auth.dart';
import '../remote/secret_store.dart';
import 'hosts_state.dart';
import 'read_list_epoch.dart';

/// 已保存的飞牛主机：fnconnect ID / DSH 网关路径，以及登录会话。
class FnosHostConfig {
  const FnosHostConfig({required this.target, this.name});

  factory FnosHostConfig.fromJson(Map<String, Object?> json) {
    final id = json['fnconnectId'];
    if (id is! String || id.isEmpty) throw const FormatException('fnconnectId missing');
    final gateway = json['gatewayPath'];
    final target = parseFnConnectInput(
      id,
      gatewayPath: gateway is String && gateway.isNotEmpty ? gateway : null,
    );
    if (target == null) throw FormatException('invalid fnconnect id: $id');
    final name = json['name'];
    return FnosHostConfig(target: target, name: name is String && name.isNotEmpty ? name : null);
  }

  final FnConnectTarget target;

  /// 用户可见的名字（默认就用 fnconnect ID）。
  final String? name;

  String get fnconnectId => target.fnconnectId;

  /// 显式保存过的网关路径；等于默认值时省略。
  String? get gatewayPath => target.gatewayPath == defaultDshGatewayPath ? null : target.gatewayPath;

  Map<String, Object?> toJson() => {
    'fnconnectId': target.fnconnectId,
    if (name != null) 'name': name,
    'gatewayPath': ?gatewayPath,
  };
}

/// 飞牛主机的配置与会话：配置进 SharedPreferences，会话 Cookie 进安全存储。
class FnosHostState {
  const FnosHostState({this.config, this.session, this.loaded = false});

  /// 还没配置主机时为 null。
  final FnosHostConfig? config;

  /// 登录过的飞牛会话；为空表示需要（重新）登录。
  final FnosSession? session;

  /// 本地配置读完之前为 false。
  final bool loaded;

  bool get configured => config != null;
  bool get signedIn => session != null;

  FnosHostState copyWith({
    FnosHostConfig? config,
    FnosSession? session,
    bool? loaded,
    bool clearSession = false,
  }) => FnosHostState(
    config: config ?? this.config,
    session: clearSession ? null : (session ?? this.session),
    loaded: loaded ?? this.loaded,
  );
}

class FnosHostController extends Notifier<FnosHostState> {
  static const prefsKey = 'fnos_host_v1';
  static const _sessionKey = 'fnos_session';
  late Future<void> _loaded;

  SecretStore get _secrets => ref.read(secretStoreProvider);

  @override
  FnosHostState build() {
    _loaded = _load();
    return const FnosHostState();
  }

  /// 读完本地配置；写入会等它，避免早期保存覆盖磁盘上的内容。
  Future<void> get ready => _loaded;

  Future<void> _load() async {
    FnosHostConfig? config;
    FnosSession? session;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) config = FnosHostConfig.fromJson(decoded);
      }
    } catch (_) {
      // 没有 preferences 后端（测试）或坏数据：当作未配置。
    }
    try {
      final raw = await _secrets.read(_sessionKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) session = FnosSession.fromJson(decoded);
      }
    } catch (_) {
      // 安全存储不可用或坏数据：当作未登录。
    }
    if (!ref.mounted) return;
    state = FnosHostState(config: config, session: session, loaded: true);
  }

  /// 保存主机（fnconnect ID / 网关路径）。换到另一台 NAS 时旧会话作废。
  Future<void> saveTarget(FnConnectTarget target, {String? name}) async {
    await _loaded;
    final changed = state.config?.fnconnectId != target.fnconnectId;
    final config = FnosHostConfig(target: target, name: name);
    ref.read(readListCredentialEpochProvider.notifier).advance();
    state = FnosHostState(config: config, session: changed ? null : state.session, loaded: true);
    if (changed) await _secrets.delete(_sessionKey);
    ref.read(activeHostProvider.notifier).select(HostRef.fnos(target.fnconnectId, name: name));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(config.toJson()));
    } catch (_) {
      // 内存里已经生效；下次启动重新配置即可。
    }
  }

  /// 只改网关路径（同一台 NAS），保留已登录的会话；路径非法时返回 null。
  Future<FnConnectTarget?> saveGatewayPath(String path) async {
    await _loaded;
    final config = state.config;
    if (config == null) return null;
    final target = config.target.withGatewayPath(path);
    if (target == null) return null;
    await saveTarget(target, name: config.name);
    return target;
  }

  /// 记住登录得到的飞牛会话 Cookie。
  Future<void> saveSession(String cookieHeader) async {
    await _loaded;
    final session = FnosSession.now(cookieHeader);
    ref.read(readListCredentialEpochProvider.notifier).advance();
    state = state.copyWith(session: session, loaded: true);
    try {
      await _secrets.write(_sessionKey, jsonEncode(session.toJson()));
    } catch (_) {
      // 写不进安全存储：本次运行仍可用，下次启动要重新登录。
    }
  }

  /// 只清会话（重新登录），保留 fnconnect ID 与网关路径。
  Future<void> clearSession() async {
    await _loaded;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    state = state.copyWith(clearSession: true, loaded: true);
    try {
      await _secrets.delete(_sessionKey);
    } catch (_) {}
  }

  /// 退出登录并忘记这台 NAS。
  Future<void> forget() async {
    await _loaded;
    ref.read(readListCredentialEpochProvider.notifier).advance();
    state = const FnosHostState(loaded: true);
    try {
      await _secrets.delete(_sessionKey);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {}
    unawaited(clearFnosCookies());
    if (ref.read(activeHostProvider).kind == HostKind.fnos) {
      ref.read(activeHostProvider.notifier).select(HostRef.local);
    }
  }
}

final fnosHostProvider = NotifierProvider<FnosHostController, FnosHostState>(FnosHostController.new);
