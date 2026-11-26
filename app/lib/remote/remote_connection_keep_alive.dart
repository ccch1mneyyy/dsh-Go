import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';

/// Hold the CPU awake while the selected remote link connects or carries data.
final remoteConnectionKeepAliveProvider = Provider<void>((ref) {
  final host = ref.watch(activeHostProvider);
  if (host.isLocal) return;
  final link = ref.watch(hostLinkProvider(host));
  if (link == null) return;
  const channel = MethodChannel('dsh/runtime');
  String? last;
  void update(String? message) {
    if (last == message) return;
    last = message;
    unawaited(channel.invokeMethod<void>('setRemoteConnectionStatus', {'message': message}));
  }

  void observe(HostLinkStatus status) => update(switch (status.phase) {
    HostLinkPhase.connecting => appL10n.remoteConnecting,
    HostLinkPhase.connected => appL10n.remoteConnected,
    HostLinkPhase.reconnecting => appL10n.remoteReconnecting,
    HostLinkPhase.failed || HostLinkPhase.idle => null,
  });

  final sub = link.statuses.listen(observe);
  observe(link.status);
  ref.onDispose(() {
    unawaited(sub.cancel());
    update(null);
  });
});
