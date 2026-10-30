# Vendored byte-stream WebSocket implementation

Source: dart-lang/web_socket_channel 2.4.5, BSD-3-Clause (LICENSE alongside).
Original file SHA-256 values are in UPSTREAM.json. Original copyright headers remain.

Only the stream framing code and its channel wrapper are retained. channel.dart
removes the platform connector imports and connect(Uri) factory; Codex supplies
its own HTTP Upgrade over SSH. Other source files are unmodified.

The 2.x package pins package:web to 0.5.x, which conflicts with DSH Go's current
Flutter plugins. The 3.x package removed the arbitrary-byte-stream constructor.
Vendoring this small transport subset avoids overriding browser dependencies or
exposing an extra local TCP listener. Codex normalizes Uint8List byte offsets
before decoding; protocol_test.dart covers this SSH-specific case.
