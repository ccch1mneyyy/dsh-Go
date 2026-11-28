import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';

/// Open a conversation at the newest line, or at a switched version's prompt.
class ChatReveal {
  const ChatReveal(this.sessionId, this.serial, {this.host, this.promptSeq, this.afterReply = false});

  final String sessionId;
  final HostRef? host;
  final int? promptSeq;
  final bool afterReply;

  /// Counts requests, so the same conversation asked twice is two changes.
  final int serial;
}

/// The app came back to a conversation to show a result (a finished phone
/// task, state/phone_turn_end.dart): its chat jumps to the bottom, wherever it
/// was scrolled. A chat opened fresh starts there anyway.
class ChatRevealController extends Notifier<ChatReveal?> {
  @override
  ChatReveal? build() => null;

  void reveal(String sessionId, {int? promptSeq, bool afterReply = false}) => state = ChatReveal(
    sessionId,
    (state?.serial ?? 0) + 1,
    host: promptSeq == null ? null : ref.read(activeHostProvider),
    promptSeq: promptSeq,
    afterReply: afterReply,
  );

  void consumeVersion(ChatReveal reveal) {
    if (identical(state, reveal)) state = null;
  }
}

final chatRevealProvider = NotifierProvider<ChatRevealController, ChatReveal?>(ChatRevealController.new);
