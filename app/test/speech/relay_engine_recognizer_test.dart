// A relay host has no `speech/*` endpoints. The phone's own engine is a
// separate connection, and its downloaded model must still serve voice calls.

import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/composer_fakes.dart';

class _RelayCarrier extends FakeRpcCarrier {
  _RelayCarrier() : super({});

  @override
  String get kind => 'remote-relay';

  @override
  bool allowsEndpoint(String endpoint) => false;
}

class _Local extends LocalConnectionController {
  _Local(this.connection);

  final HostConnection? connection;

  @override
  Future<HostConnection?> build() async => connection;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({VoiceSettingsController.preferenceKey: 'engine'}));

  test('a call on a relay recognizes with the phone engine', () async {
    final localCarrier = FakeRpcCarrier({
      'speech/catalog': (_) => readySpeechCatalog(),
      'speech/transcribe': (_) => {'text': 'recognized on the phone', 'audioSeconds': 1},
    });
    final relayCarrier = _RelayCarrier();
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(client: DshClient.withCarrier(relayCarrier), isLocal: false)),
        ),
        localConnectionProvider.overrideWith(
          () => _Local(HostConnection(client: DshClient.withCarrier(localCarrier), isLocal: true)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);

    final cloud = await container.read(callRecognizerProvider)();
    expect(cloud, isA<EngineVoiceCloud>());
    expect(await cloud!.transcribe(Uint8List(44)), 'recognized on the phone');
    expect(localCarrier.calls.map((call) => call.$1), contains('speech/transcribe'));
    expect(relayCarrier.calls, isEmpty);
  });


  test('a relay uses the account signed in on the phone engine', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"credential":"account"}')
        ..close();
    });
    final local = HostConnection(
      client: DshClient.withCarrier(
        DshHttpCarrier(DshConnection(Uri.parse('http://127.0.0.1:${server.port}'))),
      ),
      isLocal: true,
    );
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(client: DshClient.withCarrier(_RelayCarrier()), isLocal: false)),
        ),
        localConnectionProvider.overrideWith(() => _Local(local)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);

    final speech = await container.read(deepSeekSpeechProvider)();
    expect(speech, isA<BridgeDeepSeekSpeech>());
    expect(speech!.route, DeepSeekSpeechRoute.account);
    speech.close();
  });

  test('with no local engine the call still has no recognizer', () async {
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(client: DshClient.withCarrier(_RelayCarrier()), isLocal: false)),
        ),
        localConnectionProvider.overrideWith(() => _Local(null)),
      ],
    );
    addTearDown(container.dispose);
    expect(await container.read(callRecognizerProvider)(), isNull);
  });
}
