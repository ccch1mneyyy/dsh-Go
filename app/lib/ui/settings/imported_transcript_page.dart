// One imported conversation: what was said on the phone before this app ever saw
// it.
//
// Two ways in: [ImportedTranscriptPage] is the read-only page (from the drawer of
// imported chats in 设置), and [ImportedHistoryInline] is the same bubbles drawn
// inside an otherwise empty chat, so opening an imported conversation shows the
// history instead of a blank page.
//
// The session that carries it holds the turns from here; this is the part the
// host never received, so it is drawn plainly (speaker, words, the sources
// DeepSeek cited, the files that were attached) and is not editable.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/deepseek_export.dart';
import '../../import/imported_chats.dart';
import '../../l10n/l10n.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

Future<void> openImportedTranscript(BuildContext context, ImportedChat chat) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ImportedTranscriptPage(chat: chat)));

class ImportedTranscriptPage extends ConsumerStatefulWidget {
  const ImportedTranscriptPage({super.key, required this.chat});

  final ImportedChat chat;

  @override
  ConsumerState<ImportedTranscriptPage> createState() => _ImportedTranscriptPageState();
}

class _ImportedTranscriptPageState extends ConsumerState<ImportedTranscriptPage> {
  late Future<List<DeepSeekMessage>?> _transcript;

  @override
  void initState() {
    super.initState();
    _transcript = ref.read(importedChatsProvider.notifier).transcript(widget.chat.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppPage(
      title: widget.chat.title.isEmpty ? l10n.hubDeepSeekRecordTitle : widget.chat.title,
      subtitle: Text('${widget.chat.messageCount} ${l10n.hubDeepSeekImportMessages}'),
      slivers: [
        FutureBuilder<List<DeepSeekMessage>?>(
          future: _transcript,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()));
            }
            final messages = snapshot.data ?? const <DeepSeekMessage>[];
            if (messages.isEmpty) {
              return SliverFillRemaining(hasScrollBody: false, child: Center(child: Text(l10n.hubDeepSeekRecordEmpty)));
            }
            return SliverList.builder(
              itemCount: messages.length,
              itemBuilder: (context, index) => ImportedMessageBubble(message: messages[index]),
            );
          },
        ),
      ],
    );
  }
}

/// The stored history of one imported conversation, read **by session id**.
///
/// Keyed by the id on purpose: the chat page swaps this column in place when
/// another conversation is opened, and a widget that owns the future keeps
/// whatever it read first — that is what drew the first conversation's history
/// under every title. A family cannot: another id is another provider.
final importedTranscriptProvider = FutureProvider.autoDispose.family<List<DeepSeekMessage>?, String>(
  (ref, sessionId) => ref.watch(importedChatsProvider.notifier).transcript(sessionId),
);

/// The title the transcript file itself was written with: which conversation a
/// file on disk really belongs to.
final importedStoredTitleProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, sessionId) => ref.watch(importedChatsProvider.notifier).storedTitle(sessionId),
);

/// The history of one imported conversation, drawn as a column: the chat page
/// puts it under the header of a session that has no turns of its own yet.
class ImportedHistoryInline extends ConsumerWidget {
  const ImportedHistoryInline({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final transcript = ref.watch(importedTranscriptProvider(sessionId));
    final storedTitle = ref.watch(importedStoredTitleProvider(sessionId)).value;
    final messages = transcript.value ?? const <DeepSeekMessage>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Row(
            children: [
              Icon(AppIcons.history, size: 16, color: colors.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${l10n.hubDeepSeekRecordTitle} · ${messages.length} ${l10n.hubDeepSeekImportMessages}'
                  ' · ${sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId}'
                  ' · ${storedTitle ?? '-'}',
                  style: theme.textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        if (transcript.isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (messages.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text(l10n.hubDeepSeekRecordEmpty)),
          )
        else
          for (final message in messages) ImportedMessageBubble(message: message),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Text(
            l10n.hubDeepSeekImportCarryNote,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// One message of an imported conversation.
class ImportedMessageBubble extends StatelessWidget {
  const ImportedMessageBubble({super.key, required this.message});

  final DeepSeekMessage message;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fromUser = message.role == DeepSeekRole.user;
    final body = theme.textTheme.bodyMedium;
    return Padding(
      padding: EdgeInsets.fromLTRB(fromUser ? 44 : 12, 6, fromUser ? 12 : 44, 6),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: fromUser ? colors.primaryContainer.withValues(alpha: 0.55) : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fromUser ? l10n.hubDeepSeekRecordYou : l10n.hubDeepSeekRecordDeepSeek,
              style: theme.textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (message.thinking.isNotEmpty) ...[
              const SizedBox(height: 6),
              _Folded(label: l10n.hubDeepSeekRecordThinking, text: message.thinking),
            ],
            if (message.text.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectionArea(child: Text(message.text, style: body)),
            ],
            if (message.searchQueries.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('🔍 ${message.searchQueries.join(' · ')}', style: theme.textTheme.bodySmall),
            ],
            if (message.attachments.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '${l10n.hubDeepSeekRecordAttachments}: ${message.attachments.map((a) => a.name).join('、')}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (message.sources.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(l10n.hubDeepSeekRecordSources, style: theme.textTheme.labelSmall),
              for (final source in message.sources.take(8))
                Text(
                  source.title.isEmpty ? source.url : source.title,
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
            if (message.stopped) ...[
              const SizedBox(height: 6),
              Text(l10n.hubDeepSeekRecordStopped, style: theme.textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _Folded extends StatefulWidget {
  const _Folded({required this.label, required this.text});

  final String label;
  final String text;

  @override
  State<_Folded> createState() => _FoldedState();
}

class _FoldedState extends State<_Folded> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.label, style: theme.textTheme.labelSmall),
              Icon(_open ? AppIcons.collapse : AppIcons.expand, size: 14, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.text,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}
