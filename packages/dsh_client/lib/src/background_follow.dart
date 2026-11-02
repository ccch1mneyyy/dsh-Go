/// Typed decoding of large follow baselines, after the carrier's JSON decode.
library;

import 'dart:async';
import 'dart:isolate';

import 'json.dart';
import 'models.dart';

const _backgroundEventThreshold = 256;

FutureOr<DshEvent> decodeFollowBaseline(String sessionId, Object? value, {bool isResync = false}) {
  final map = asMap(value);
  if (map?['type'] == 'snapshot' && _largeBaseline(map!)) {
    // Wire data has no local follow identity yet. The watcher attaches its
    // original epoch after decoding and checking that generation is current.
    return Isolate.run(() => parseFollowFrame(sessionId, value, isResync: isResync));
  }
  return parseFollowFrame(sessionId, value, isResync: isResync);
}

bool _largeBaseline(JsonMap map) {
  var count = asListOrEmpty(map['records']).length;
  if (count >= _backgroundEventThreshold) return true;
  final stream = asMap(map['assistantStream']);
  final attempt = asMap(stream?['activeAttempt']);
  for (final record in asListOrEmpty(attempt?['stream'])) {
    final chunk = asMapOrEmpty(record);
    count += switch (chunk['type']) {
      'text-chunks' || 'reasoning-chunks' => asListOrEmpty(chunk['texts']).length,
      'tool-call-chunks' => asListOrEmpty(chunk['args']).length,
      _ => 1,
    };
    if (count >= _backgroundEventThreshold) return true;
  }
  return false;
}
