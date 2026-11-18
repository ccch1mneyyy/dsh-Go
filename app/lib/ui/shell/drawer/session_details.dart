// 长按 › 详情: 这条对话是什么、从哪儿来、什么时候开始和结束。
//
// 导入的 DeepSeek 会话把官方的两个时间戳(创建 / 最后一条)留在导入索引里,
// 所以这里的日期是 DeepSeek App 里那份导出包里的时间,不是导入这一刻。
import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../import/deepseek_export.dart' show DeepSeekMessage;
import '../../../import/imported_chats.dart';
import '../../../l10n/l10n.dart';
import '../../common/app_sheet.dart';
import '../../theme/app_icons.dart';
import '../sessions_drawer.dart' show sessionTitle;

/// 2026-11-18 14:32
String _stamp(DateTime at) {
  final local = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

Future<void> showSessionDetails(BuildContext context, WidgetRef ref, SessionSummary session) async {
  final l10n = context.l10n;
  final imported = ref.read(importedIndexProvider)[session.sessionId];
  // 导出包里的两个时间:创建、最后一条。索引里没有(旧版本导入的)就回到这条
  // 对话自己的记录上取,总之不是导入这一刻。
  var created = imported?.sourceCreatedAt;
  var updated = imported?.sourceUpdatedAt;
  if (imported != null && (created == null || updated == null)) {
    final messages = await ref.read(importedChatsProvider.notifier).transcript(session.sessionId);
    final stamps = <DateTime>[
      for (final message in messages ?? const <DeepSeekMessage>[])
        if (message.at != null) message.at!,
    ]..sort();
    if (stamps.isNotEmpty) {
      created ??= stamps.first;
      updated ??= stamps.last;
    }
  }
  final createdAt = created ?? session.updatedAt;
  final updatedAt = updated ?? session.updatedAt;
  if (!context.mounted) return;
  await showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetHeader(sessionTitle(session)),
              SheetGroup(
                children: [
                  _DetailRow(
                    icon: AppIcons.info,
                    label: l10n.shellDetailsSource,
                    value: imported == null ? l10n.shellDetailsSourceLocal : l10n.shellDetailsSourceImport,
                  ),
                  _DetailRow(icon: AppIcons.history, label: l10n.shellDetailsCreated, value: _stamp(createdAt)),
                  _DetailRow(icon: AppIcons.history, label: l10n.shellDetailsUpdated, value: _stamp(updatedAt)),
                  if (imported != null)
                    _DetailRow(
                      icon: AppIcons.chat,
                      label: l10n.shellDetailsMessages,
                      value: '${imported.messageCount}',
                    ),
                  _DetailRow(icon: AppIcons.copy, label: l10n.shellDetailsId, value: session.sessionId, copyable: true),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    ),
  );
  // The sheet above already closed; nothing else to do.
}

class _DetailRow extends ConsumerWidget {
  const _DetailRow({required this.icon, required this.label, required this.value, this.copyable = false});

  final IconData icon;
  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ListTile(
      leading: Icon(icon, color: colors.onSurfaceVariant),
      title: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
      subtitle: Text(
        value,
        style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      ),
      trailing: copyable
          ? IconButton(
              icon: const Icon(AppIcons.copy),
              tooltip: context.l10n.shellDetailsCopyId,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(content: Text(context.l10n.shellDetailsCopied)),
                );
              },
            )
          : null,
    );
  }
}
