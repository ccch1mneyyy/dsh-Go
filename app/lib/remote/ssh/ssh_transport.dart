import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../diagnostics/redact.dart';
import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'remote_shell.dart';
import 'ssh_host_config.dart';

/// A byte pipe to `host:port` on the remote side of the SSH connection.
abstract class TunnelChannel {
  Stream<Uint8List> get stream;
  StreamSink<List<int>> get sink;
  void destroy();
}

/// A reachable SSH server refused the destination TCP connection.
class TunnelRefused implements Exception {
  const TunnelRefused([this.cause]);
  final Object? cause;

  @override
  String toString() => 'TunnelRefused: $cause';
}

/// Host key presented by the server: algorithm and OpenSSH-style
/// `SHA256:<base64>` fingerprint (same text `ssh-keygen -lf` prints).
class PresentedHostKey {
  const PresentedHostKey(this.type, this.fingerprint);

  final String type;
  final String fingerprint;

  /// `ED25519` / `RSA` / `ECDSA` for display.
  String get shortType {
    final t = type.toLowerCase();
    if (t.contains('ed25519')) return 'ED25519';
    if (t.contains('rsa')) return 'RSA';
    if (t.contains('ecdsa')) return 'ECDSA';
    return type;
  }
}

/// Decides whether to trust the server's key. Return false to abort.
typedef HostKeyCheck = FutureOr<bool> Function(PresentedHostKey key);

/// Everything needed to open one SSH connection.
class SshConnectParams {
  const SshConnectParams({
    required this.host,
    required this.port,
    required this.username,
    required this.auth,
    required this.secrets,
    this.compression = true,
    this.connectTimeout = const Duration(seconds: 12),
  });

  factory SshConnectParams.of(SshHostConfig config, SshSecrets secrets) => SshConnectParams(
    host: config.host.trim(),
    port: config.port,
    username: config.user.trim(),
    auth: config.auth,
    secrets: secrets,
    compression: config.compression,
  );

  final String host;
  final int port;
  final String username;
  final SshAuthMethod auth;
  final SshSecrets secrets;
  final bool compression;
  final Duration connectTimeout;
}

/// One authenticated SSH connection.
abstract class SshTransport implements RemoteShell {
  /// Opens a direct-tcpip channel to [host]:[port] as seen from the server.
  Future<TunnelChannel> openTunnel(String host, int port);

  /// Round-trips a keepalive; throws or times out when the link is dead.
  Future<void> ping({Duration timeout = const Duration(seconds: 10)});

  /// Completes when the connection closes for any reason.
  Future<void> get done;

  bool get isClosed;

  void close();
}

typedef SshTransportFactory = Future<SshTransport> Function(SshConnectParams params, HostKeyCheck verifyHostKey);

/// Cipher preference used for every connection.
///
/// AES-GCM used to come first (dartssh2's own default). PointyCastle's GCM
/// does its GF(2^128) multiply bit by bit: `gcm.dart:_mult` runs 128 rounds of
/// three byte-wide passes with no tables, so a single 16-byte block costs
/// roughly 6k byte operations. On 1.0.4 that one function took 73.6% of the UI
/// isolate while a long session was streaming, which is what starved frames.
/// AES-CTR has no such multiply: in the AOT microbenchmark it decrypts 3.1
/// MiB/s where GCM manages 0.5, so it leads the list.
///
/// ChaCha20-Poly1305 is deliberately last. It is the one cipher whose Terrapin
/// (CVE-2023-48795) prefix truncation works on *every* connection that did not
/// negotiate strict KEX, and dartssh2 enables strict KEX only when the server
/// offers it. Putting it after both AES-GCM entries means it is picked only
/// when the server offers nothing else - i.e. only in the cases where
/// dartssh2's default order (GCM first) would have picked it too. AES-CTR is
/// not a practical Terrapin target: that needs a CBC cipher, and CBC is never
/// offered here (oss-security advisory, 2023-12-18).
///
/// This is only a reorder: every cipher dartssh2 enables by default stays in
/// the list, so a server offering nothing but AES-GCM still negotiates it.
/// CBC, SHA-1 kex and `none` are never added.
///
/// Leading with AES-CTR costs one thing: AES-CTR needs a MAC, while the AEAD
/// ciphers need none, so a peer that offers AES-CTR but only MACs dartssh2 does
/// not implement (e.g. `umac-128-etm@openssh.com`) cannot negotiate with this
/// list at all. [DartSshTransport.connect] covers that case: it retries once
/// with dartssh2's AEAD-first order when MAC selection is what failed.
const sshCipherPreference = <SSHCipherType>[
  SSHCipherType.aes256ctr,
  SSHCipherType.aes128ctr,
  SSHCipherType.aes256gcm,
  SSHCipherType.aes128gcm,
  SSHCipherType.chacha20poly1305,
];

/// `fast` applies [sshCipherPreference]; `legacy` keeps dartssh2's original
/// order, so one build can compare the two with
/// `--dart-define=DSH_SSH_CIPHER=legacy`.
const _sshCipherProfile = String.fromEnvironment('DSH_SSH_CIPHER', defaultValue: 'fast');

/// Throws on anything but `fast` / `legacy`: a typo in the build define should
/// fail before the socket opens rather than quietly pick a preference.
SSHAlgorithms sshClientAlgorithms({String profile = _sshCipherProfile}) =>
    switch (profile) {
      'fast' => const SSHAlgorithms(cipher: sshCipherPreference),
      'legacy' => const SSHAlgorithms(),
      _ => throw ArgumentError.value(profile, 'profile', 'expected fast or legacy'),
    };

/// `--dart-define=DSH_SSH_TRACE=cipher` in a profile build prints the
/// negotiated kex, cipher and MAC once per key exchange. Never in release.
const _sshTrace = String.fromEnvironment('DSH_SSH_TRACE');
const _traceNegotiation = !kReleaseMode && _sshTrace == 'cipher';

/// Keeps only what a perf A/B needs to read; passing null otherwise keeps
/// dartssh2's per-packet debug callbacks from costing anything. The library
/// prints the kex line as `_kexType`, the strict-KEX verdict as `_strictKex`,
/// and the negotiated algorithms as `...CipherType` / `...MacType`. The last
/// two lines are what the A/B run reads; `_strictKex` says whether the
/// Terrapin countermeasure negotiated.
const _traceKeys = <String>['_kexType', '_strictKex', 'CipherType', 'MacType'];

void _printNegotiation(String? line) {
  if (line == null) return;
  if (_traceKeys.any(line.contains)) debugPrint('dsh-ssh $line');
}

/// A handshake that failed because the negotiated cipher needs a MAC that is
/// not available; [DartSshTransport.connect] catches it to retry once.
class _MacNegotiationFailure implements Exception {
  const _MacNegotiationFailure(this.cause);
  final Object cause;
}

/// dartssh2-backed transport.
class DartSshTransport implements SshTransport, RemoteBootstrapShell {
  /// Takes ownership of an authenticated client, including closing it.
  DartSshTransport.fromClient(this._client);

  final SSHClient _client;

  static Future<SshTransport> connect(SshConnectParams params, HostKeyCheck verifyHostKey) async {
    // Resolved first so a bad DSH_SSH_CIPHER fails before the socket opens;
    // throwing later would leave the connection without a close path.
    final algorithms = sshClientAlgorithms();
    final identities = await _resolveIdentities(params);
    try {
      return await _open(params, verifyHostKey, identities, algorithms);
    } on _MacNegotiationFailure catch (failure) {
      // sshCipherPreference leads with AES-CTR, which needs a MAC that both
      // sides implement. A peer that offers AES-CTR but only MACs dartssh2 does
      // not know (e.g. umac-128-etm@openssh.com) would fail to negotiate at
      // all, where dartssh2's AEAD-first order never negotiates a MAC. Retry
      // with that order so those peers keep connecting.
      if (algorithms.cipher.first.isAead) throw describeSshError(failure.cause, params);
      if (_traceNegotiation) debugPrint('dsh-ssh no matching MAC; retrying with the AEAD-first cipher order');
      try {
        return await _open(params, verifyHostKey, identities, sshClientAlgorithms(profile: 'legacy'));
      } on _MacNegotiationFailure catch (retryFailure) {
        throw describeSshError(retryFailure.cause, params);
      }
    }
  }

  /// Decodes the key or vets the password before a socket is opened.
  static Future<List<SSHKeyPair>?> _resolveIdentities(SshConnectParams params) async {
    if (params.auth == SshAuthMethod.privateKey) {
      return decodePrivateKey(params.secrets.privateKey ?? '', params.secrets.passphrase);
    }
    if ((params.secrets.password ?? '').isEmpty) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.remoteErrPasswordMissing);
    }
    return null;
  }

  /// One socket, one handshake, up to authentication.
  ///
  /// A handshake that fails because the negotiated cipher needs a MAC that is
  /// not available is rethrown as [_MacNegotiationFailure], so [connect] can
  /// retry with another cipher order instead of reporting an unreachable host.
  static Future<DartSshTransport> _open(
    SshConnectParams params,
    HostKeyCheck verifyHostKey,
    List<SSHKeyPair>? identities,
    SSHAlgorithms algorithms,
  ) async {
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(params.host, params.port, timeout: params.connectTimeout);
    } on SocketException catch (e) {
      throw describeSocketError(e, params);
    } on TimeoutException {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrAddressUnresponsive(params.host, params.port),
        retryable: true,
      );
    }

    HostLinkError? keyVerdict;
    final client = SSHClient(
      socket,
      username: params.username,
      compression: params.compression,
      algorithms: algorithms,
      printDebug: _traceNegotiation ? _printNegotiation : null,
      identities: identities,
      onPasswordRequest: params.auth == SshAuthMethod.password ? () => params.secrets.password : null,
      // Keyboard-interactive servers ask for the same password.
      onUserInfoRequest: params.auth == SshAuthMethod.password
          ? (request) => [for (final _ in request.prompts) params.secrets.password ?? '']
          : null,
      onVerifyHostKey: (type, fingerprint) async {
        final key = PresentedHostKey(type, utf8.decode(fingerprint, allowMalformed: true));
        try {
          return await verifyHostKey(key);
        } on HostLinkError catch (e) {
          keyVerdict = e;
          return false;
        }
      },
      // The link runs its own keepalive with a timeout (dartssh2's never
      // notices a dead socket on its own).
      keepAliveInterval: null,
      handshakeTimeout: const Duration(seconds: 20),
      authTimeout: const Duration(seconds: 30),
    );
    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      if (keyVerdict != null) throw keyVerdict!;
      if (isMacNegotiationFailure(e)) throw _MacNegotiationFailure(e);
      throw describeSshError(e, params);
    }
    return DartSshTransport.fromClient(client);
  }

  /// Whether dartssh2 gave up because the cipher it negotiated needs a MAC and
  /// none of the peer's MACs are implemented by the library.
  ///
  /// The library wraps the cause - [SSHAuthAbortError], then
  /// [SSHInternalError], then the [StateError] raised while negotiating - so
  /// read through those before matching the message. Only the two messages
  /// `_handleMessageKexInit` throws are matched.
  static bool isMacNegotiationFailure(Object error) {
    Object? cause = error;
    for (var depth = 0; depth < 4; depth++) {
      final current = cause;
      if (current is SSHAuthAbortError) {
        cause = current.reason;
      } else if (current is SSHInternalError) {
        cause = current.error;
      } else {
        break;
      }
    }
    if (cause is! StateError) return false;
    final message = cause.message;
    return message == 'No matching client MAC algorithm' || message == 'No matching server MAC algorithm';
  }

  /// Parses a PEM private key, mapping failures to a person-readable error.
  static Future<List<SSHKeyPair>> decodePrivateKey(String pem, String? passphrase) async {
    final text = pem.trim();
    if (text.isEmpty) {
      throw HostLinkError(HostLinkErrorKind.badPrivateKey, appL10n.remoteErrPrivateKeyMissing);
    }
    try {
      final pass = (passphrase == null || passphrase.isEmpty) ? null : passphrase;
      // PEM parsing and the encrypted-key KDF are synchronous CPU work.
      // Keep localization on the caller isolate; send only key material.
      final pairs = await Isolate.run(() {
        if (pass == null && SSHKeyPair.isEncryptedPem(text)) return null;
        return SSHKeyPair.fromPem(text, pass);
      }, debugName: 'ssh-private-key');
      if (pairs == null) {
        throw HostLinkError(HostLinkErrorKind.badPrivateKey, appL10n.remoteErrKeyNeedsPassword);
      }
      if (pairs.isEmpty) throw const FormatException('no keys');
      return pairs;
    } on HostLinkError {
      rethrow;
    } on SSHKeyDecryptError catch (e) {
      throw HostLinkError(HostLinkErrorKind.badPrivateKey, appL10n.remoteErrKeyPassword, detail: e.message);
    } catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.badPrivateKey,
        appL10n.remoteErrKeyUnreadable,
        detail: appL10n.remotePrivateKeyFormats(e.toString()),
      );
    }
  }

  static HostLinkError describeSocketError(SocketException e, SshConnectParams params) {
    final os = e.osError?.message ?? e.message;
    final text = '$os ${e.message}'.toLowerCase();
    final where = '${params.host}:${params.port}';
    if (text.contains('refused')) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrAddressRejected(where),
        detail: os,
        retryable: true,
      );
    }
    if (text.contains('host lookup') || text.contains('name') && text.contains('resol') || text.contains('nodename')) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrSshHostNotFound(params.host),
        detail: os,
        retryable: true,
      );
    }
    return HostLinkError(
      HostLinkErrorKind.unreachable,
      appL10n.remoteErrSshAddressUnresponsive(where),
      detail: os,
      retryable: true,
    );
  }

  static HostLinkError describeSshError(Object e, SshConnectParams params) {
    if (e is HostLinkError) return e;
    if (e is SSHAuthAbortError) {
      final reason = e.reason;
      if (reason is SSHHostkeyError) return describeSshError(reason, params);
      // dartssh2 uses a null reason for EOF and authentication deadlines, and a
      // peer can report the loss itself (RFC 4253 reason 10).
      // The link owns cancellation; explicit peer refusals stay terminal below.
      if (reason == null ||
          reason is SSHSocketError ||
          (reason is SSHDisconnectError && reason.reasonCode == _disconnectConnectionLost)) {
        return HostLinkError(
          HostLinkErrorKind.unreachable,
          appL10n.remoteErrSshInterrupted,
          detail: ['$e', if (reason != null) '$reason'].join('\n'),
          retryable: true,
        );
      }
    }
    if (e is SSHAuthError) {
      return HostLinkError(
        HostLinkErrorKind.authFailed,
        params.auth == SshAuthMethod.password ? appL10n.remoteErrUsernamePassword : appL10n.remoteErrPrivateKeyRejected,
        detail: params.auth == SshAuthMethod.privateKey
            ? appL10n.remoteAuthorizedKeysHelp(params.username, e.toString())
            : '$e',
      );
    }
    if (e is SSHHostkeyError) {
      return HostLinkError(HostLinkErrorKind.hostKeyRejected, appL10n.remoteErrFingerprintUntrusted, detail: '$e');
    }
    if (e is SocketException) return describeSocketError(e, params);
    if (e is TimeoutException) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrSshHandshakeTimeout,
        detail: '$e',
        retryable: true,
      );
    }
    final text = '$e';
    if (e is SSHHandshakeError || e is SSHSocketError || e is SSHStateError || e is SSHDisconnectError) {
      return HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrSshInterrupted,
        detail: text,
        retryable: true,
      );
    }
    return HostLinkError(HostLinkErrorKind.other, appL10n.remoteErrSshConnection, detail: text, retryable: true);
  }

  @override
  Future<RemoteExecResult> runBootstrap(String script, {required Duration timeout}) {
    final random = Random.secure();
    final nonce = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final marker = 'DSHAPP_DONE_$nonce';
    final out = _BootstrapOutput(marker, 'stdout');
    final err = _BootstrapOutput(marker, 'stderr');
    // Each stream's frame follows all of that stream's script output,
    // including the log tail after an exited/timeout result.
    final trap =
        r'_dsh_status=$?; trap - 0; '
        'printf ${shQuote('\n$marker stdout %s\n')} "\$_dsh_status"; '
        'printf ${shQuote('\n$marker stderr %s\n')} "\$_dsh_status" >&2; '
        r'exit "$_dsh_status"';
    // Keep any login-profile EXIT handler outside this script's trap.
    final command = loginShell('(\ntrap ${shQuote(trap)} 0\n$script\n)');
    final completed = Completer<RemoteExecResult>();
    SSHSession? session;
    StreamSubscription<Uint8List>? stdoutSubscription;
    StreamSubscription<Uint8List>? stderrSubscription;
    var stdoutDone = false;
    var stderrDone = false;
    var channelDone = false;
    var settled = false;
    late final Timer timer;

    void cleanUp() {
      timer.cancel();
      unawaited(stdoutSubscription?.cancel());
      unawaited(stderrSubscription?.cancel());
      // close() alone may wait for a peer that never closes its output.
      session?.channel.destroy();
    }

    void fail(Object error, StackTrace stack) {
      if (settled) return;
      settled = true;
      out.finish();
      err.finish();
      cleanUp();
      if (error is! TimeoutException && error is! SSHError) {
        completed.completeError(error, stack);
        return;
      }
      final timeoutError = error is TimeoutException;
      final stdout = _bootstrapDiagnostic(out.text());
      final stderr = _bootstrapDiagnostic(err.text());
      completed.completeError(
        HostLinkError(
          HostLinkErrorKind.unreachable,
          timeoutError ? appL10n.remoteErrCommandTimeout : appL10n.remoteErrSshInterrupted,
          retryable: true,
          detail: [
            redactRemoteTokens(timeoutError ? 'after $timeout' : '$error'),
            if (stdout.isNotEmpty) 'stdout:\n$stdout',
            if (stderr.isNotEmpty) 'stderr:\n$stderr',
          ].join('\n'),
        ),
        stack,
      );
    }

    void finishIfReady() {
      if (settled) return;
      final framed = out.status != null && out.status == err.status;
      if (!framed && !(stdoutDone && stderrDone && channelDone)) return;
      settled = true;
      out.finish();
      err.finish();
      final result = RemoteExecResult(
        framed ? out.status : session!.exitCode,
        out.text(beforeFrame: framed),
        err.text(beforeFrame: framed),
      );
      cleanUp();
      completed.complete(result);
    }

    // One deadline includes opening the session. execute has no public
    // handle to cancel until it returns; reclaim a late session below.
    timer = Timer(timeout, () => fail(TimeoutException('bootstrap', timeout), StackTrace.current));
    unawaited(
      _client.execute(command).then<void>((opened) {
        if (settled) {
          opened.channel.destroy();
          return;
        }
        session = opened;
        stdoutSubscription = opened.stdout.listen(
          (data) {
            out.bytes(data);
            finishIfReady();
          },
          onDone: () {
            out.finish();
            stdoutDone = true;
            finishIfReady();
          },
          onError: fail,
        );
        stderrSubscription = opened.stderr.listen(
          (data) {
            err.bytes(data);
            finishIfReady();
          },
          onDone: () {
            err.finish();
            stderrDone = true;
            finishIfReady();
          },
          onError: fail,
        );
        unawaited(
          opened.done.then<void>((_) {
            channelDone = true;
            finishIfReady();
          }, onError: fail),
        );
      }, onError: fail),
    );
    return completed.future;
  }

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async {
    final SSHRunResult result;
    try {
      result = await _client.runWithResult(loginShell(script)).timeout(timeout);
    } on TimeoutException {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrCommandTimeout,
        retryable: true,
        detail: 'after $timeout',
      );
    } on SSHError catch (e) {
      throw HostLinkError(
        HostLinkErrorKind.unreachable,
        appL10n.remoteErrSshInterrupted,
        detail: '$e',
        retryable: true,
      );
    }
    return RemoteExecResult(
      result.exitCode,
      utf8.decode(result.stdout, allowMalformed: true),
      utf8.decode(result.stderr, allowMalformed: true),
    );
  }

  @override
  Future<TunnelChannel> openTunnel(String host, int port) async {
    try {
      final channel = await _client.forwardLocal(host, port, localHost: '127.0.0.1');
      return _ForwardChannel(channel);
    } on SSHChannelOpenError catch (e) {
      // 2 = SSH_OPEN_CONNECT_FAILED: nothing listens on that port anymore.
      if (e.code == 2) throw TunnelRefused(e);
      rethrow;
    }
  }

  @override
  Future<void> ping({Duration timeout = const Duration(seconds: 10)}) => _client.ping().timeout(timeout);

  @override
  Future<void> get done => _client.done.catchError((_) {});

  @override
  bool get isClosed => _client.isClosed;

  @override
  void close() => unawaited(Future.sync(_client.close).catchError((_) {}));
}

class _ForwardChannel implements TunnelChannel {
  _ForwardChannel(this._channel);

  final SSHForwardChannel _channel;

  @override
  Stream<Uint8List> get stream => _channel.stream;

  @override
  StreamSink<List<int>> get sink => _channel.sink;

  @override
  void destroy() => _channel.destroy();
}

// The frame recognizer keeps only a bounded suffix between chunks; collecting
// diagnostics must not rescan the whole output after every SSH packet.
class _BootstrapOutput implements Sink<String> {
  _BootstrapOutput(String marker, String stream)
    : _frame = RegExp('\n${RegExp.escape(marker)} $stream ([0-9]{1,3})\r?\n'),
      _frames = RegExp('\n${RegExp.escape(marker)} (?:stdout|stderr) [0-9]{1,3}\r?\n'),
      _suffixLength = marker.length + stream.length + 8;

  final RegExp _frame;
  final RegExp _frames;
  final int _suffixLength;
  final _output = StringBuffer();
  late final _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(this);
  var _suffix = '';
  var _frameStart = 0;
  var _finished = false;
  int? status;

  void bytes(Uint8List bytes) => _decoder.add(bytes);

  @override
  void add(String chunk) {
    final previousLength = _output.length;
    _output.write(chunk);
    // A merged stderr can still follow the stdout frame. Keep those bytes
    // until both expected frames arrive or the ordinary EOF path completes.
    if (status != null) return;
    final scan = _suffix + chunk;
    final match = _frame.firstMatch(scan);
    if (match != null && int.parse(match[1]!) <= 255) {
      status = int.parse(match[1]!);
      _frameStart = previousLength - _suffix.length + match.start;
      _suffix = '';
      return;
    }
    _suffix = scan.length <= _suffixLength ? scan : scan.substring(scan.length - _suffixLength);
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    _decoder.close();
  }

  @override
  void close() {}

  String text({bool beforeFrame = false}) {
    final value = _output.toString();
    return (beforeFrame ? value.substring(0, _frameStart) : value).replaceAll(_frames, '');
  }
}

/// SSH_DISCONNECT_CONNECTION_LOST.
const _disconnectConnectionLost = 10;

String _bootstrapDiagnostic(String text) {
  final redacted = redactDiagnostics(redactRemoteTokens(text)).trim();
  const limit = 4096;
  return redacted.length <= limit ? redacted : '…\n${redacted.substring(redacted.length - limit)}';
}
