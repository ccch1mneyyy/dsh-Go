import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_state.dart';
import '../../state/engine_control.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../settings/settings_widgets.dart';

/// Explicit LAN access: off by default, with a trusted-Wi-Fi confirmation.
class LanAccessSettings extends ConsumerStatefulWidget {
  const LanAccessSettings({super.key});

  @override
  ConsumerState<LanAccessSettings> createState() => _LanAccessSettingsState();
}

class _LanAccessSettingsState extends ConsumerState<LanAccessSettings> {
  bool _busy = false;
  String? _failure;

  Future<bool> _confirm(bool enabling) async {
    final l10n = context.l10n;
    if (!enabling) return true;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.lanAccessTitle),
        content: Text(l10n.lanAccessWarning),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            key: const ValueKey('lan-access-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.lanAccessEnable),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _change(bool next) async {
    if (_busy) return;
    final container = ProviderScope.containerOf(context, listen: false);
    if (!await _confirm(next)) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await EngineControl.setLanAccess(container, enabled: next);
    } catch (error) {
      if (mounted) setState(() => _failure = error is PlatformException ? error.code : 'lan_access_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) showBriefNotice(context, context.l10n.commonCopied);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localRuntimeProvider);
    final status = state.status;
    final l10n = context.l10n;
    final canChange = state.loaded && !status.runtimeMissing && !_busy && !status.phase.isBusy;
    final lanBaseUrl = status.lanBaseUrl;
    final url = status.isRunning && status.lanAccessEnabled && lanBaseUrl != null && status.token != null
        ? Uri.parse(lanBaseUrl).resolve('login').toString()
        : null;
    return SettingsSection(
      title: l10n.lanAccessTitle,
      children: [
        SettingsSwitchTile(
          key: const ValueKey('lan-access-switch'),
          title: l10n.lanAccessEnable,
          subtitle: status.lanAccessEnabled
              ? l10n.lanAccessHintOn
              : l10n.lanAccessHint,
          value: status.lanAccessEnabled,
          onChanged: canChange ? (next) => unawaited(_change(next)) : null,
        ),
        if (url != null)
          SettingsTile(
            key: const ValueKey('lan-access-copy'),
            title: l10n.lanAccessCopyAddress,
            subtitle: url,
            onTap: () => unawaited(_copy(url)),
          ),
        if (_failure case final failure?)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(
              switch (failure) {
                'runtime_not_stopped' || 'runtime_not_stopped_after_lan_access' => l10n.phoneSafeStopIncomplete,
                'lan_access_unavailable' => l10n.lanAccessUnavailable,
                'missing_plugin' => l10n.lanAccessUnavailable,
                _ => l10n.lanAccessFailed,
              },
              key: const ValueKey('lan-access-error'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}
