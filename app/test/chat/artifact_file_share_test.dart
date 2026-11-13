// 交付文件「分享」: through the files channel, whose native side starts the
// system chooser in a task of its own. Started from this app's task instead,
// the chooser joins it, and the app the person picks (WeChat, …) keeps its own
// screens there — the recent-tasks card says DSH Go and 「返回」 stays in that
// app (#1130, the same symptom as #217).

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';

const _channel = MethodChannel('dsh/files');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a delivered file is shared through the files channel', () async {
    final shares = <Map<String, Object?>>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'resolveGuest':
          return '/sdcard/Download/DSH-Go/笔记.md';
        case 'share':
          shares.add((call.arguments as Map).cast<String, Object?>());
          return null;
      }
      throw StateError('unexpected ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));

    final connection = HostConnection(client: DshClient.withCarrier(FakeRpcCarrier({})), isLocal: true);
    addTearDown(connection.client.close);
    final files = ArtifactFiles(connection: connection, channel: const FilesChannel());

    await files.share('session-1', const Artifact(path: '/home/me/笔记.md', origin: ArtifactOrigin.linked, turn: 3));

    expect(shares, [
      {'path': '/sdcard/Download/DSH-Go/笔记.md', 'name': '笔记.md', 'mime': 'text/markdown'},
    ]);
  });
}
