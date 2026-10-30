import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'package:codex_backend/codex_backend.dart';
import 'package:codex_client/ssh_connection.dart';
import 'package:dsh_client/dsh_client.dart';

import '../link_status.dart';
import '../ssh/ssh_link.dart';
import '../ssh/ssh_host_config.dart';
import '../ssh/ssh_transport.dart';

class CodexHostLink implements HostLink {
  CodexHostLink({
    required this.config,
    required this.loadSecrets,
    this.pinHostKey,
    this.promptHostKey,
    Stream<void>? kicks,
    required this.submissionLedger,
  }) {
    _kicks = kicks?.listen((_) => kick());
  }
  SshHostConfig config;
  final Map<String, Future<String>> submissionLedger;
  final Future<SshSecrets> Function() loadSecrets;
  final HostKeyPinner? pinHostKey;
  final HostKeyPrompter? promptHostKey;
  final _statuses = StreamController<HostLinkStatus>.broadcast();
  final _clients = StreamController<DshClient>.broadcast();
  StreamSubscription<void>? _kicks;
  SshConnection? _connection;
  CodexChatClient? _client;
  Future<DshClient>? _opening;
  Timer? _retry;
  Timer? _probe;
  int _attempt = 0;
  bool _closed = false;
  bool _checking = false;
  @override
  HostLinkStatus status = HostLinkStatus.idle;
  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;
  @override
  Stream<DshClient> get clients => _clients.stream;
  @override
  DshClient? get currentClient => status.isConnected ? _client : null;
  String? get resolvedWorkingDirectory {
    final path = config.workingDirectory;
    if (path == null) return null;
    return path == '~'
        ? '/home/${config.user}'
        : path.startsWith('~/')
        ? '/home/${config.user}/${path.substring(2)}'
        : path;
  }

  void _emit(HostLinkStatus s) {
    if (!_closed) {
      status = s;
      _statuses.add(s);
    }
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('连接已关闭'));
    if (currentClient case final c?) return Future.value(c);
    return _opening ??= _connect().whenComplete(() => _opening = null);
  }

  Future<DshClient> _connect() async {
    _retry?.cancel();
    _emit(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    SshConnection? connection;
    CodexChatClient? pendingClient;
    HostLinkError? trustError;
    try {
      final secrets = await loadSecrets();
      connection = await SshConnection.open(
        host: config.host,
        port: config.port,
        username: config.user,
        binary: config.codexBinary?.trim().isNotEmpty == true
            ? config.codexBinary!
            : '/home/${config.user}/.codex/packages/app-server-daemon/current/bin/codex',
        socket: config.codexSocket?.trim().isNotEmpty == true
            ? config.codexSocket!
            : '/home/${config.user}/.codex/app-server-control/app-server-control.sock',
        password: config.auth == SshAuthMethod.password ? secrets.password : null,
        privateKey: config.auth == SshAuthMethod.privateKey ? secrets.privateKey : null,
        passphrase: secrets.passphrase,
        verifyHostKey: (type, fingerprint) async {
          final key = PresentedHostKey(type, fingerprint);
          if (config.hostKeyFingerprint == fingerprint) return true;
          if (config.hostKeyFingerprint != null) {
            trustError = hostKeyMismatchError(config, key);
            return false;
          }
          if (promptHostKey == null ||
              !await promptHostKey!(HostKeyPrompt(hostName: config.name, address: config.address, key: key))) {
            trustError = const HostLinkError(HostLinkErrorKind.hostKeyUnverified, '请先测试连接并确认主机指纹');
            return false;
          }
          await pinHostKey?.call(key);
          config = config.copyWith(hostKeyType: () => type, hostKeyFingerprint: () => fingerprint);
          return true;
        },
      );
      final account = await connection.client.account();
      if (account['account'] == null) throw const HostLinkError(HostLinkErrorKind.notLoggedIn, '请先在服务器登录 Codex');
      if (_closed) throw StateError('连接已关闭');
      final client = pendingClient = CodexChatClient(
        connection.client,
        files: connection.files,
        home: '/home/${config.user}',
        cwd: resolvedWorkingDirectory,
        submissionLedger: submissionLedger,
      );
      await client.ready();
      if (_closed) {
        await client.close();
        throw StateError('连接已关闭');
      }
      final old = _connection;
      final oldClient = _client;
      _connection = connection;
      _client = client;
      _attempt = 0;
      _emit(const HostLinkStatus(HostLinkPhase.connected));
      _clients.add(client);
      if (oldClient != null) unawaited(oldClient.close());
      if (old != null) unawaited(old.close());
      final owned = connection;
      connection.client.done.then((_) {
        if (!_closed && identical(_connection, owned)) _lost();
      });
      _probe?.cancel();
      _probe = Timer.periodic(const Duration(seconds: 25), (_) => kick());
      return client;
    } catch (e) {
      await pendingClient?.close();
      await connection?.close();
      final error =
          trustError ??
          (e is HostLinkError
              ? e
              : e is SSHAuthFailError
              ? const HostLinkError(HostLinkErrorKind.authFailed, 'SSH 认证失败，请检查登录信息')
              : HostLinkError(
                  HostLinkErrorKind.other,
                  'Codex 连接失败',
                  detail: '$e',
                  retryable: e is SocketException || e is TimeoutException,
                ));
      _emit(HostLinkStatus(HostLinkPhase.failed, error: error));
      throw error;
    }
  }

  void _lost() {
    _probe?.cancel();
    _emit(HostLinkStatus(HostLinkPhase.reconnecting, attempt: ++_attempt));
    _retry?.cancel();
    _retry = Timer(Duration(seconds: (_attempt * 2).clamp(2, 30)), () => retry());
  }

  @override
  void kick() {
    if (_closed || _checking) return;
    if (!status.isConnected) {
      if (status.error != null && !status.error!.retryable) return;
      retry();
      return;
    }
    _checking = true;
    _connection!.client
        .account()
        .then(
          (_) {},
          onError: (Object _) {
            if (!_closed) unawaited(_connection?.close());
          },
        )
        .whenComplete(() => _checking = false);
  }

  @override
  void retry() {
    if (_closed || _opening != null) return;
    unawaited(
      open()
          .catchError((Object e) {
            // Authentication and trust errors require explicit user action.
            if (!_closed && e is HostLinkError && e.retryable) _lost();
            throw e;
          })
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retry?.cancel();
    _probe?.cancel();
    await _kicks?.cancel();
    await _client?.close();
    await _connection?.close();
    unawaited(_statuses.close());
    unawaited(_clients.close());
  }
}
