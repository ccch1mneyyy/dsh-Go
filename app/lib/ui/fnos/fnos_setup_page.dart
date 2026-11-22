import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../fnos/fnconnect.dart';
import '../../fnos/fnos_webview.dart';
import '../../l10n/l10n.dart';
import '../../state/fnos_host_state.dart';
import '../common/brief_notice.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';

/// 添加（或修改）一台飞牛 NAS：只填 fnconnect ID，必要时再改 DSH 网关路径，
/// 然后弹出一次飞牛登录页。
class FnosSetupPage extends ConsumerStatefulWidget {
  const FnosSetupPage({super.key});

  @override
  ConsumerState<FnosSetupPage> createState() => _FnosSetupPageState();
}

class _FnosSetupPageState extends ConsumerState<FnosSetupPage> {
  late final TextEditingController _id;
  late final TextEditingController _gateway;
  bool _advanced = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config = ref.read(fnosHostProvider).config;
    _id = TextEditingController(text: config?.fnconnectId ?? '');
    _gateway = TextEditingController(text: config?.gatewayPath ?? '');
    _advanced = config?.gatewayPath != null;
  }

  @override
  void dispose() {
    _id.dispose();
    _gateway.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final l10n = context.l10n;
    final gateway = _gateway.text.trim();
    final target = parseFnConnectInput(_id.text.trim(), gatewayPath: gateway.isEmpty ? null : gateway);
    if (target == null) {
      setState(() => _error = gateway.isEmpty ? l10n.fnosIdInvalid : l10n.fnosGatewayInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final hosts = ref.read(fnosHostProvider.notifier);
    try {
      await hosts.saveTarget(target, name: target.fnconnectId);
      if (!mounted) return;
      final cookie = await FnosLoginPage.show(context, target: target);
      if (!mounted) return;
      if (cookie == null || cookie.isEmpty) {
        setState(() => _error = l10n.fnosLoginIncomplete);
        return;
      }
      await hosts.saveSession(cookie);
      if (!mounted) return;
      showBriefNotice(context, l10n.fnosSignedIn);
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return AppPage.list(
      title: l10n.fnosHostTitle,
      subtitle: Text(l10n.fnosHostIntro),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SettingsSection(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const ValueKey('fnos-fnconnect-id'),
                      controller: _id,
                      enabled: !_busy,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _busy ? null : (_) => unawaited(_submit()),
                      decoration: InputDecoration(
                        labelText: l10n.fnosFnconnectId,
                        hintText: 'mynas',
                        prefixText: 'https://',
                        suffixText: '.fnos.net',
                        helperText: l10n.fnosFnconnectIdHint,
                        helperMaxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        key: const ValueKey('fnos-gateway-advanced'),
                        initiallyExpanded: _advanced,
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: EdgeInsets.zero,
                        onExpansionChanged: (open) => setState(() => _advanced = open),
                        title: Text(l10n.fnosGatewayAdvanced, style: theme.textTheme.bodyMedium),
                        subtitle: Text(
                          '${l10n.fnosGatewayDefaultLabel} $defaultDshGatewayPath',
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        ),
                        children: [
                          TextField(
                            key: const ValueKey('fnos-gateway-path'),
                            controller: _gateway,
                            enabled: !_busy,
                            autocorrect: false,
                            enableSuggestions: false,
                            keyboardType: TextInputType.url,
                            decoration: InputDecoration(
                              labelText: l10n.fnosGatewayPath,
                              hintText: defaultDshGatewayPath,
                              helperText: l10n.fnosGatewayHint,
                              helperMaxLines: 3,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final path in commonDshGatewayPaths)
                                  ActionChip(
                                    label: Text(path, style: theme.textTheme.bodySmall),
                                    onPressed: _busy ? null : () => setState(() => _gateway.text = path),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_error case final error?) ...[
                      const SizedBox(height: 8),
                      Text(
                        error,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const ValueKey('fnos-login'),
                      onPressed: _busy ? null : () => unawaited(_submit()),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.fnosLoginNext),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.fnosLoginHint,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: SettingsSection(
            footer: Text(
              l10n.fnosLoginHint,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
            ),
            children: [
              InfoRow(label: l10n.fnosGatewayPath, value: defaultDshGatewayPath, mono: true),
            ],
          ),
        ),
      ],
    );
  }
}
