import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'codex_client.dart';
import 'ssh_files.dart';

class SshConnection {
  SshConnection._(this.client, this._ssh, this._session, this._stderr);
  final CodexClient client;
  late final SshCodexFiles files = SshCodexFiles(_ssh);
  final SSHClient _ssh;
  final SSHSession _session;
  final StreamSubscription<Uint8List> _stderr;

  static Future<SshConnection> open({
    required String host,
    required int port,
    required String username,
    required String binary,
    required String socket,
    required Future<bool> Function(String type, String fingerprint)
    verifyHostKey,
    String? password,
    String? privateKey,
    String? passphrase,
    void Function(String)? onProgress,
  }) async {
    final command = proxyCommand(binary, socket);
    onProgress?.call('连接 SSH…');
    final transport = await SSHSocket.connect(
      host,
      port,
      timeout: const Duration(seconds: 12),
    );
    SSHClient? ssh;
    SSHSession? session;
    StreamSubscription<Uint8List>? stderr;
    CodexClient? client;
    try {
      ssh = SSHClient(
        transport,
        username: username,
        identities: privateKey == null || privateKey.isEmpty
            ? null
            : SSHKeyPair.fromPem(privateKey, passphrase),
        onPasswordRequest: password == null || password.isEmpty
            ? null
            : () => password,
        onVerifyHostKey: (type, fingerprint) =>
            verifyHostKey(type, utf8.decode(fingerprint)),
        handshakeTimeout: const Duration(minutes: 2),
        authTimeout: const Duration(seconds: 30),
        keepAliveInterval: const Duration(seconds: 20),
      );
      unawaited(ssh.done.catchError((Object _) {}));
      await ssh.authenticated;
      onProgress?.call('连接 Codex 服务…');
      session = await ssh.execute(command).timeout(const Duration(seconds: 15));
      // Never mix stderr with the binary protocol, or log remote diagnostics
      // which may contain account information.
      stderr = session.stderr.listen((_) {}, onError: (Object _) {});
      final channel = session;
      client = await CodexClient.connect(
        input: channel.stdout,
        write: (bytes) => channel.stdin.add(Uint8List.fromList(bytes)),
        closeTransport: channel.close,
      );
      await client.initialize();
      return SshConnection._(client, ssh, session, stderr);
    } catch (_) {
      await client?.close();
      session?.close();
      await stderr?.cancel();
      ssh?.close();
      if (ssh == null) transport.close();
      rethrow;
    }
  }

  Future<void> close() async {
    await client.close();
    _session.close();
    await _stderr.cancel();
    _ssh.close();
  }
}
