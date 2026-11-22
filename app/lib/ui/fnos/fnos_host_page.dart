import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../fnos/fnconnect.dart';
import '../../fnos/fnos_webview.dart';
import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/fnos_host_state.dart';
import '../../state/hosts_state.dart';
import 'fnos_setup_page.dart';
import '../common/app_dialog.dart';
import '../common/brief_notice.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

/// 已经添加的飞牛 NAS：状态、重新登录、改网关路径、忘记。
class FnosHostPage extends ConsumerStatefulWidget {
  const FnosHostPage({super.key});

  @override
  ConsumerState<FnosHostPage> createState() => _FnosHostPageState();
}

class _FnosHostPageState extends ConsumerState<FnosHostPage> {
  bool _busy = false;

  Future<void> _relogin() async {
    final config = ref.read(fnosHostProvider).config;
    if (config == null || _busy) return;
    setState(() => _busy = true);
    try {
      final cookie = await FnosLoginPage.show(context, target: config.target);
      if (!mounted) return;
      if (cookie == null || cookie.isEmpty) {
        showBriefNotice(context, context.l10n.fnosLoginIncomplete);
        return;
      }
      await ref.read(fnosHostProvider.notifier).saveSession(cookie);
      if (!mounted) return;
      showBriefNotice(context, context.l10n.fnosSignedIn);
      ref.read(remoteConnectionProvider(ref.read(activeHostProvider)).notifier).retry();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editGateway() async {
    final config = ref.read(fnosHostProvider).config;
    if (config == null) return;
    final controller = TextEditingController(text: config.target.gatewayPath);
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.fnosGatewayPath),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: defaultDshGatewayPath,
            helperText: context.l10n.fnosGatewayHint,
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(context.l10n.commonSave),
          ),
        ],
      ),
    );
    if (path == null || !mounted) return;
    final target = await ref.read(fnosHostProvider.notifier).saveGatewayPath(path);
    if (!mounted) return;
    if (target == null) {
      showBriefNotice(context, context.l10n.fnosGatewayInvalid);
      return;
    }
    ref.read(remoteConnectionProvider(ref.read(activeHostProvider)).notifier).retry();
    showBriefNotice(context, target.gatewayPath);
  }

  Future<void> _forget() async {
    final l10n = context.l10n;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.fnosForget),
        content: Text(l10n.fnosForgetConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(l10n.commonDelete)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(fnosHostProvider.notifier).forget();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = ref.watch(fnosHostProvider);
    final active = ref.watch(activeHostProvider);
    final connection = ref.watch(activeConnectionProvider);
    final config = host.config;
    if (config == null) {
      return AppPage.list(title: l10n.fnosHostTitle, children: const []);
    }
    final isActive = active.kind == HostKind.fnos && active.id == config.fnconnectId;
    final status = !isActive
        ? l10n.fnosNotSignedIn
        : connection.when(
            data: (c) => c == null ? l10n.fnosNotSignedIn : l10n.fnosSignedIn,
            error: (_, _) => l10n.fnosNotSignedIn,
            loading: () => l10n.fnosNotSignedIn,
          );
    return AppPage.list(
      title: l10n.fnosHostTitle,
      subtitle: Text(config.target.dshBaseUri.toString()),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SettingsSection(
            title: l10n.fnosStatus,
            children: [
              InfoRow(label: l10n.fnosFnconnectId, value: config.fnconnectId),
              InfoRow(label: l10n.fnosStatus, value: status),
              InfoRow(label: l10n.fnosGatewayPath, value: config.target.gatewayPath, mono: true),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SettingsSection(
            children: [
              SettingsTile(
                icon: AppIcons.refresh,
                tinted: false,
                title: l10n.fnosRelogin,
                onTap: _busy ? null : () => unawaited(_relogin()),
              ),
              SettingsTile(
                icon: AppIcons.configure,
                tinted: false,
                title: l10n.fnosGatewayPath,
                value: Text(config.target.gatewayPath),
                onTap: () => unawaited(_editGateway()),
              ),
              SettingsTile(
                icon: AppIcons.add,
                tinted: false,
                title: l10n.fnosChangeId,
                onTap: _busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const FnosSetupPage()),
                      ),
              ),
              SettingsTile(
                icon: AppIcons.disconnected,
                tinted: false,
                danger: true,
                title: l10n.fnosForget,
                subtitle: l10n.fnosForgetHint,
                onTap: _busy ? null : () => unawaited(_forget()),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
