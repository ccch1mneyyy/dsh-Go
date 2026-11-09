import 'package:dsh_app/remote/relay/webrtc_audio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('FlutterWebRTC.Method');

  test('libwebrtc is initialized with the media audio configuration, once', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await ensureWebRtcAudioConfiguration();
    await ensureWebRtcAudioConfiguration();

    expect(calls.map((call) => call.method), ['initialize']);
    final arguments = calls.single.arguments as Map;
    expect((arguments['options'] as Map)['androidAudioConfiguration'], {
      'manageAudioFocus': false,
      'androidAudioMode': 'normal',
      'androidAudioStreamType': 'music',
      'androidAudioAttributesUsageType': 'media',
      'androidAudioAttributesContentType': 'speech',
    });
  });
}
