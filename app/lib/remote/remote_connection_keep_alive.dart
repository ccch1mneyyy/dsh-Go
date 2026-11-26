import 'package:flutter/services.dart';

/// Android foreground-service bridge for an active encrypted remote connection.
class RemoteConnectionKeepAlive {
  static const _channel = MethodChannel('dsh/app');

  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setRemoteConnectionKeepAlive', {'enabled': enabled});
    } on MissingPluginException {
      // iOS, HarmonyOS and desktop do not have this Android service.
    }
  }
}
