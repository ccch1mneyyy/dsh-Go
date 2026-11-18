// 通用 › 导入 DeepSeek APP 端聊天记录.
//
// One page, three states: what to pick, where the import is, and what it did.
// The conversations become real sessions on the host (so the drawer, renaming,
// pinning and deleting all work on them) and their history is kept aside for
// the first message sent from here.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../import/deepseek_export.dart';
import '../../import/deepseek_importer.dart';
import '../../import/imported_chats.dart';
import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'imported_transcript_page.dart';
import 'settings_widgets.dart';

/// The path of the export to import, or null when nothing was picked. Tests
/// swap it.
final deepSeekImportPickerProvider = Provider<Future<String?> Function()>(
  (ref) => () async =>
      (await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['zip']))?.path,
);

/// Downloads the archive a DeepSeek export link points at and returns its path.
/// Tests swap it.
final deepSeekExportDownloaderProvider =
    Provider<Future<String> Function(String link, void Function(double fraction) onProgress)>(
      (ref) => downloadDeepSeekExport,
    );

/// Fetches `link` (a signed OBS url from 设置 › 导出数据) into the app's temporary
/// directory. Follows redirects, and reports how much of the body has arrived.
Future<String> downloadDeepSeekExport(String link, void Function(double fraction) onProgress) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(link));
    request.followRedirects = true;
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(link));
    }
    final total = response.contentLength;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/deepseek_data-import.zip');
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress((received / total).clamp(0.0, 1.0));
      }
    } finally {
      await sink.close();
    }
    onProgress(1);
    return file.path;
  } finally {
    client.close(force: true);
  }
}

const _gutter = EdgeInsets.fromLTRB(16, 6, 16, 6);

enum _Stage { idle, downloading, reading, creating, finished, failed }

class DeepSeekImportPage extends ConsumerStatefulWidget {
  const DeepSeekImportPage({super.key});

  @override
  ConsumerState<DeepSeekImportPage> createState() => _DeepSeekImportPageState();
}

class _DeepSeekImportPageState extends ConsumerState<DeepSeekImportPage> {
  _Stage _stage = _Stage.idle;
  String? _problem;
  DeepSeekImportOutcome? _outcome;
  int _done = 0;
  int _total = 0;
  bool _cancelRequested = false;
  DateTime _lastPaint = DateTime.fromMillisecondsSinceEpoch(0);

  /// 从链接导入用:链接本身、下载进度和链接的问题。
  final _link = TextEditingController();
  double _progress = 0;
  String? _linkProblem;

  bool get _busy => _stage == _Stage.downloading || _stage == _Stage.reading || _stage == _Stage.creating;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final picker = ref.read(deepSeekImportPickerProvider);
    final path = await picker();
    if (path == null || !mounted) return;
    await _run(path);
  }

  /// 从链接导入:DeepSeek 官网给的是一个带签名的下载地址,先下到临时目录,
  /// 再交给同一个读取器和导入器 —— 和手动选 zip 走的是同一条路。
  Future<void> _startFromLink() async {
    final link = _link.text.trim();
    final uri = Uri.tryParse(link);
    final isLink = uri != null && (uri.isScheme('http') || uri.isScheme('https')) && link.toLowerCase().contains('.zip');
    if (!isLink) {
      setState(() => _linkProblem = context.l10n.hubDeepSeekImportLinkBad);
      return;
    }
    setState(() {
      _linkProblem = null;
      _problem = null;
      _outcome = null;
      _progress = 0;
      _stage = _Stage.downloading;
    });
    final String path;
    try {
      path = await ref.read(deepSeekExportDownloaderProvider)(link, (fraction) {
        if (mounted) setState(() => _progress = fraction);
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _problem = '${context.l10n.hubDeepSeekImportDownloadFailed} $error';
      });
      return;
    }
    if (!mounted) return;
    await _run(path);
  }

  Future<void> _run(String path) async {
    if (ref.read(activeConnectionProvider).value == null) {
      setState(() {
        _stage = _Stage.failed;
        _problem = context.l10n.hubDeepSeekImportNoHost;
      });
      return;
    }
    setState(() {
      _stage = _Stage.reading;
      _problem = null;
      _outcome = null;
      _cancelRequested = false;
      _done = 0;
      _total = 0;
    });

    final DeepSeekExport export;
    try {
      export = await readDeepSeekExport(path);
    } on DeepSeekExportException catch (error) {
      if (!mounted) return;
      final l10n = context.l10n;
      setState(() {
        _stage = _Stage.failed;
        _problem = switch (error.problem) {
          DeepSeekExportProblem.notAnExport => l10n.hubDeepSeekImportBadZip,
          DeepSeekExportProblem.noChats => l10n.hubDeepSeekImportNoChatsZip,
          DeepSeekExportProblem.unreadable => l10n.hubDeepSeekImportUnreadable,
        };
      });
      return;
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _problem = '${context.l10n.hubDeepSeekImportUnreadable} $error';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _stage = _Stage.creating;
      _total = export.conversations.length;
    });

    try {
      final outcome = await runDeepSeekImport(
        ref: ref,
        export: export,
        onProgress: (done, total) {
          // 几百个会话时每完成一个都重建整页会把导入拖慢:按时间节流。
          final now = DateTime.now();
          if (now.difference(_lastPaint) < const Duration(milliseconds: 120) && done < total) return;
          _lastPaint = now;
          if (mounted) setState(() => _done = done);
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      setState(() {
        _stage = _Stage.finished;
        _outcome = outcome;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _problem = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final imported = ref.watch(importedChatsProvider).value ?? const <ImportedChat>[];
    return AppPage.list(
      title: l10n.hubDeepSeekImport,
      children: [
        SettingsSection(
          title: l10n.hubDeepSeekImportFromLink,
          footer: Text(l10n.hubDeepSeekImportLinkHint),
          children: [
            Padding(
              padding: _gutter,
              child: TextField(
                controller: _link,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                minLines: 1,
                maxLines: 3,
                style: Theme.of(context).textTheme.bodySmall,
                decoration: InputDecoration(
                  labelText: l10n.hubDeepSeekImportLinkLabel,
                  border: const OutlineInputBorder(),
                  errorText: _linkProblem,
                ),
              ),
            ),
            Padding(
              padding: _gutter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_stage == _Stage.downloading) ...[
                    LinearProgressIndicator(value: _progress <= 0 ? null : _progress),
                    const SizedBox(height: 8),
                    Text(
                      l10n.hubDeepSeekImportDownloading((_progress * 100).round()),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                  ],
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _busy ? null : () => unawaited(_startFromLink()),
                      child: Text(l10n.hubDeepSeekImportLinkStart),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsSection(
          footer: Text(l10n.hubDeepSeekImportHint),
          children: [
            SettingsTile(
              icon: AppIconsForImport.pick,
              title: l10n.hubDeepSeekImportPick,
              subtitle: _busy ? _busyLine(l10n) : null,
              chevron: !_busy,
              onTap: _busy ? null : () => unawaited(_start()),
            ),
          ],
        ),
        if (_busy && _stage != _Stage.downloading)
          _ProgressCard(done: _done, total: _total, stage: _stage, onCancel: () => setState(() => _cancelRequested = true)),
        if (_problem != null) _ProblemCard(text: _problem!),
        if (_outcome != null) _OutcomeCard(outcome: _outcome!, total: _total),
        if (_outcome == null && !_busy) _CarryNote(text: l10n.hubDeepSeekImportCarryNote),
        SettingsSection(
          title: l10n.hubDeepSeekImportImportedSection,
          children: [
            if (imported.isEmpty)
              Padding(padding: _gutter, child: Text(l10n.hubDeepSeekImportNone, style: Theme.of(context).textTheme.bodySmall)),
            for (final chat in imported)
              SettingsTile(
                icon: AppIconsForImport.record,
                title: chat.title.isEmpty ? l10n.hubDeepSeekRecordTitle : chat.title,
                subtitle: '${chat.messageCount} ${l10n.hubDeepSeekImportMessages}',
                onTap: () => unawaited(openImportedTranscript(context, chat)),
              ),
          ],
        ),
      ],
    );
  }

  String _busyLine(L10n l10n) => switch (_stage) {
    _Stage.downloading => l10n.hubDeepSeekImportDownloading((_progress * 100).round()),
    _Stage.reading => l10n.hubDeepSeekImportParsing,
    _Stage.creating => '${l10n.hubDeepSeekImportCreating} $_done / $_total',
    _ => l10n.hubDeepSeekImportPick,
  };
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.done, required this.total, required this.stage, required this.onCancel});

  final int done;
  final int total;
  final _Stage stage;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final fraction = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
    return Padding(
      padding: _gutter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: stage == _Stage.reading ? null : fraction),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  stage == _Stage.reading ? l10n.hubDeepSeekImportParsing : '$done / $total',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(onPressed: onCancel, child: Text(l10n.hubDeepSeekImportCancel)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProblemCard extends StatelessWidget {
  const _ProblemCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: _gutter,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onErrorContainer)),
      ),
    );
  }
}

class _OutcomeCard extends StatelessWidget {
  const _OutcomeCard({required this.outcome, required this.total});

  final DeepSeekImportOutcome outcome;
  final int total;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SettingsSection(
      title: outcome.cancelled ? l10n.hubDeepSeekImportCancelled : l10n.hubDeepSeekImportSummary,
      children: [
        Padding(
          padding: _gutter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${outcome.imported} / $total · ${outcome.messages} ${l10n.hubDeepSeekImportMessages}',
                style: theme.textTheme.bodyMedium,
              ),
              if (outcome.skipped > 0)
                Text(
                  '${l10n.hubDeepSeekImportSkipped} ${outcome.skipped}',
                  style: theme.textTheme.bodySmall,
                ),
              if (outcome.imported > 0)
                Text(l10n.hubDeepSeekImportWhere, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        if (outcome.problems.isNotEmpty)
          Padding(
            padding: _gutter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.hubDeepSeekImportFailed, style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                for (final problem in outcome.problems.take(5))
                  Text(problem, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
      ],
    );
  }
}

class _CarryNote extends StatelessWidget {
  const _CarryNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: _gutter,
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

/// The two icons this page uses, named here so the page does not reach into
/// [AppIcons] with a guess.
abstract final class AppIconsForImport {
  static const pick = AppIcons.download;
  static const record = AppIcons.history;
}
