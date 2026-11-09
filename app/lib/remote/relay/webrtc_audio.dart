import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The audio attributes libwebrtc's playback track gets for dsh Remote's direct
/// path.
///
/// The path carries a DataChannel only, but starting the peer connection factory
/// also builds a `JavaAudioDeviceModule`, and its player defaults to
/// `USAGE_VOICE_COMMUNICATION`: Android then treats the app as a call, so the
/// volume keys move to the call stream and every other player is ducked through
/// the call DSP, which makes everything else sound muffled and quieter than it
/// should. Nothing plays through that track, so media is both the honest usage and
/// the one that leaves other apps' playback alone.
AndroidAudioConfiguration dshRemoteAudioConfiguration() => AndroidAudioConfiguration(
  // No audio stream exists here; a focus request would only take it from other apps.
  manageAudioFocus: false,
  androidAudioMode: AndroidAudioMode.normal,
  androidAudioStreamType: AndroidAudioStreamType.music,
  androidAudioAttributesUsageType: AndroidAudioAttributesUsageType.media,
  androidAudioAttributesContentType: AndroidAudioAttributesContentType.speech,
);

Future<void>? _initialized;

/// Initializes flutter_webrtc with [dshRemoteAudioConfiguration], once.
///
/// `WebRTC.initialize` is process-global and only its first call counts (the
/// plugin initializes itself with the defaults if anything reaches it earlier), so
/// this must run before the first `createPeerConnection`. The Android-only
/// options are ignored on iOS, where this is the same call the plugin would have
/// made on its own.
Future<void> ensureWebRtcAudioConfiguration() => _initialized ??= _initialize();

Future<void> _initialize() async {
  try {
    await WebRTC.initialize(options: {'androidAudioConfiguration': dshRemoteAudioConfiguration().toMap()});
  } on Object {
    // A failed initialization must not pin every later connection attempt to it.
    _initialized = null;
    rethrow;
  }
}
