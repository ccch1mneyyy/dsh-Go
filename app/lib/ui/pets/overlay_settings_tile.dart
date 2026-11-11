// 宠物设置's 「App 外显示」 group (docs/design/pets.md §2.7, §6.4, §8): the
// switch, 有事时显示 / 一直显示, 「未授权」 with a way back to the permission,
// the restricted-settings guide on Android 13+, and 今天不再显示. Mounted by
// `PetSettingsPage`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_float.dart';
import '../../l10n/l10n.dart';
import '../../pets/overlay_channel.dart';
import '../../pets/pet_prefs.dart';
import '../common/expand_reveal.dart';
import '../common/risk_notice.dart';
import '../phone/restricted_settings_guide.dart';
import '../settings/settings_widgets.dart';

/// 「App 外显示」. Nothing without the native side (tests, desktop).
class PetOverlaySettingsSection extends ConsumerStatefulWidget {
  const PetOverlaySettingsSection({super.key});

  @override
  ConsumerState<PetOverlaySettingsSection> createState() => _PetOverlaySettingsSectionState();
}

class _PetOverlaySettingsSectionState extends ConsumerState<PetOverlaySettingsSection> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from system settings: check for real (the switch there may lie).
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(ref.read(petOverlayProvider.notifier).refresh()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// On; a permission still to grant is said first, then system settings.
  Future<void> _turnOn(PetOverlayStatus s) async {
    if (!s.permission.usable && !await confirmRisk(context, RiskNotices.petOverlay)) return;
    if (!mounted) return;
    await ref.read(petOverlayProvider.notifier).turnOn();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = ref.watch(petOverlayProvider);
    if (!s.native) return const SizedBox.shrink();
    final overlay = ref.read(petOverlayProvider.notifier);
    final on = s.working;
    // Sideloaded on Android 13+: the system switch may be greyed out until
    // 「允许受限制的设置」. Offered once a trip there came back empty.
    final restricted = s.refused && s.sdk >= 33 && s.permission != PetOverlayPermission.blocked;
    return SettingsSection(
      children: [
        SettingsSwitchTile(
          spot: Spots.petOutsideApp,
          subtitle: s.refused ? l10n.botsPetNotAuthorized : null,
          value: on,
          onChanged: (v) => unawaited(v ? _turnOn(s) : overlay.turnOff()),
        ),
        ExpandReveal(
          open: on,
          child: SettingsSegmentTile<bool>(
            spot: Spots.petDisplayWhen,
            segments: [PillSegment(false, l10n.botsPetWhenActive), PillSegment(true, l10n.botsPetAlways)],
            selected: s.alwaysShow,
            onChanged: (v) => unawaited(overlay.setAlwaysShow(v)),
          ),
        ),
        if (on) const _CompanionRendererSetting(),
        if (restricted)
          SettingsTile(
            title: l10n.botsPetSwitchDisabled,
            value: Text(l10n.botsPetRestrictedSettings),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RestrictedSettingsGuidePage(target: RestrictedTarget.overlay),
              ),
            ),
          ),
        if (on && s.snoozed)
          SettingsTile(
            title: l10n.botsPetHiddenToday,
            value: Text(l10n.botsPetRestore),
            chevron: false,
            onTap: () => unawaited(overlay.unsnooze()),
          ),
      ],
    );
  }
}

/// Reuses the existing setting row; missing/broken content is explained and
/// cannot be selected. Turning a previous choice off is always possible.
class _CompanionRendererSetting extends ConsumerWidget {
  const _CompanionRendererSetting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final prefs = ref.watch(petPrefsProvider);
    final availability = ref.watch(companionFloatAvailabilityProvider);
    final running = ref.watch(companionFloatProvider);
    final native = ref.watch(petOverlayProvider);
    final selected = prefs.overlayRenderer == PetOverlayRenderer.companion;
    final available = availability is AsyncData<String?> && availability.value == null;
    final reason = availability.hasError ? 'companion_storage' : availability.asData?.value ?? running.problem;
    String? message;
    if (availability.isLoading) {
      message = l10n.companionArriving;
    } else if (reason != null) {
      message = switch (reason) {
        'companion_runtime_missing' || 'companion_runtime_incomplete' => l10n.companionPackNoRuntime,
        'companion_runtime_mismatch' => l10n.companionPackRuntimeMismatch,
        'companion_no_model' || 'companion_missing_model' => l10n.companionPackNoModel,
        'companion_too_large' => l10n.companionPackTooLarge,
        'companion_unsafe_path' => l10n.companionPackUnsafe,
        'companion_storage' || 'companion_readers_busy' => l10n.companionPackStorage,
        'companion_native_unavailable' || 'companion_channel_failed' ||
        'companion_server_failed' || 'companion_unavailable' => l10n.companionFailedTitle,
        _ => l10n.companionPackBroken,
      };
    } else if (native.companionFallback) {
      message = '${l10n.companionFailedTitle} · ${l10n.botsPets}';
    } else {
      message = selected ? null : l10n.botsPets;
    }
    return SettingsSwitchTile(
      key: const ValueKey('pet-overlay-companion'),
      title: l10n.companionTitle,
      subtitle: message,
      value: selected,
      onChanged: selected || available ? (value) => unawaited(ref.read(petPrefsProvider.notifier)
          .setOverlayRenderer(value ? PetOverlayRenderer.companion : PetOverlayRenderer.pixel)) : null,
    );
  }
}
