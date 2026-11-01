import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ready_mux.dart';
import 'support/wait.dart';

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => _running('first');

  static LocalRuntimeState _running(String token, {String? workspaceDir}) => LocalRuntimeState(
    loaded: true,
    status: RuntimeStatus.fromMap({
      'phase': 'running',
      'baseUrl': 'http://127.0.0.1:9',
      'token': token,
      'workspaceDir': workspaceDir,
    }),
  );

  void replace(String token) => state = _running(token);

  void replaceWorkspace(String? directory) => state = _running('first', workspaceDir: directory);
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final _readyMux = ReadyMux();
  @override
  DshMux get mux => _readyMux;
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a replaced build closes its late client', () async {
    final pending = <Completer<DshClient>>[];
    final c = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localRuntimeProvider.overrideWith(_Runtime.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        localClientConnectorProvider.overrideWithValue(({required baseUri, required token}) {
          final done = Completer<DshClient>();
          pending.add(done);
          return done.future;
        }),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(localConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);
    (c.read(localRuntimeProvider.notifier) as _Runtime).replace('second');
    await Future<void>.delayed(Duration.zero);
    expect(pending, hasLength(2));
    final old = _Client();
    pending.first.complete(old);
    await Future<void>.delayed(Duration.zero);
    expect(old.closed, isTrue);
    final current = _Client();
    pending.last.complete(current);
    await until(c, localConnectionProvider, (s) => s.value != null, what: '新本机连接');
    expect(c.read(localConnectionProvider).value!.client, same(current));
    expect(current.closed, isFalse);
  });

  test('network kick restarts a failed local connection', () async {
    var attempts = 0;
    final kicks = StreamController<void>.broadcast(sync: true);
    addTearDown(kicks.close);
    final c = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localRuntimeProvider.overrideWith(_Runtime.new),
        networkKicksProvider.overrideWithValue(kicks.stream),
        localClientConnectorProvider.overrideWithValue(({required baseUri, required token}) async {
          attempts++;
          if (attempts == 1) throw const DshTransportException('offline');
          return _Client();
        }),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(localConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await until(c, localConnectionProvider, (s) => s.hasError, what: '本机连接失败');
    kicks.add(null);
    await until(c, localConnectionProvider, (s) => s.value != null, what: '网络恢复后连接');
    expect(attempts, 2);
  });

  test('同一端点工作目录更新会关闭旧连接并发布真实目录', () async {
    final clients = <_Client>[];
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localRuntimeProvider.overrideWith(_Runtime.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        localClientConnectorProvider.overrideWithValue(({required baseUri, required token}) async {
          final client = _Client();
          clients.add(client);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(localConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await until(container, localConnectionProvider, (value) => value.value != null, what: '旧版本机连接');
    expect(container.read(localConnectionProvider).value!.workingDirectory, isNull);

    const directory = '/data/test-private-runtime/home/workspace';
    (container.read(localRuntimeProvider.notifier) as _Runtime).replaceWorkspace(directory);
    await until(
      container,
      localConnectionProvider,
      (value) => !value.isLoading && value.value?.workingDirectory == directory,
      what: '实际工作目录连接',
    );
    expect(clients, hasLength(2));
    expect(clients.first.closed, isTrue);
    expect(clients.last.closed, isFalse);

    (container.read(localRuntimeProvider.notifier) as _Runtime).replaceWorkspace('  ');
    await until(
      container,
      localConnectionProvider,
      (value) => !value.isLoading && value.value?.workingDirectory == null && clients.length == 3,
      what: '空目录恢复旧版默认',
    );
    expect(clients[1].closed, isTrue);
  });

  test('工作目录换代后迟到的旧连接不能覆盖新目录', () async {
    final pending = <Completer<DshClient>>[];
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localRuntimeProvider.overrideWith(_Runtime.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        localClientConnectorProvider.overrideWithValue(({required baseUri, required token}) {
          final reply = Completer<DshClient>();
          pending.add(reply);
          return reply.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(localConnectionProvider, (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);
    const directory = '/data/test-private-runtime/second-workspace';
    (container.read(localRuntimeProvider.notifier) as _Runtime).replaceWorkspace(directory);
    await Future<void>.delayed(Duration.zero);
    expect(pending, hasLength(2));
    final retired = _Client();
    pending.first.complete(retired);
    await Future<void>.delayed(Duration.zero);
    expect(retired.closed, isTrue);
    pending.last.complete(_Client());
    await until(
      container,
      localConnectionProvider,
      (value) => value.value?.workingDirectory == directory,
      what: '新工作目录连接',
    );
  });
}
