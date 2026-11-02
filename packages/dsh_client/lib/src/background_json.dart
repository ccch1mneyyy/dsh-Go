/// Large reconnect snapshots and history pages must not monopolize the UI
/// isolate. Small streaming frames stay synchronous; callers must serialize
/// the futures returned for large messages to preserve wire order.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'json.dart';

// Measured in code units for text, bytes for HTTP bodies. Inspecting length
// does not traverse a potentially multi-megabyte payload on the calling isolate.
const backgroundJsonThreshold = 64 * 1024;

FutureOr<Object?> decodeJsonText(String text) {
  if (text.length < backgroundJsonThreshold) return tryDecodeJson(text);
  // Only capture the immutable wire text, never a carrier/socket/tracer. The
  // decoded object graph is transferred back by Isolate.run's Isolate.exit.
  return Isolate.run(() => tryDecodeJson(text));
}

FutureOr<Object?> decodeJsonBytes(Uint8List bytes) {
  if (bytes.length < backgroundJsonThreshold) {
    return tryDecodeJson(utf8.decode(bytes, allowMalformed: true));
  }
  final body = TransferableTypedData.fromList([bytes]);
  return Isolate.run(() {
    final text = utf8.decode(body.materialize().asUint8List(), allowMalformed: true);
    return tryDecodeJson(text);
  });
}
