// 宠物设置's 「App 外显示」 group and the overlay flavour of the restricted-settings
// guide (docs/design/pets.md §6.4, §8).

import 'package:dsh_app/companion/companion_float.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/ui/common/risk_notice.dart';
import 'package:dsh_app/ui/pets/overlay_settings_tile.dart';
import 'package:dsh_app/ui/phone/restricted_settings_guide.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../phone/harness.dart';
import '../../shell/golden_harness.dart';
import 'fake_overlay_native.dart';

Widget _page() => const Scaffold(
  body: SafeArea(child: SingleChildScrollView(child: PetOverlaySettingsSection())),
);

class _QuietFloatController extends CompanionFloatController {
  @override CompanionFloatState build() => const CompanionFloatState();
}

Future<void> _pump(WidgetTester tester, {Brightness brightness = Brightness.light, double height = 520,
  String? companionProblem = 'companion_runtime_missing'}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(390, height) * 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(goldenApp(home: _page(), brightness: brightness, overrides: [
    companionFloatAvailabilityProvider.overrideWith((ref) => Stream.value(companionProblem)),
    companionFloatProvider.overrideWith(_QuietFloatController.new),
  ]));
  await settlePhone(tester);
}

/// 「App 外显示」 without the permission: the first-time notice, then 去设置.
Future<void> _turnOnThroughNotice(WidgetTester tester) async {
  await tester.tap(find.text('App 外显示'));
  await settlePhone(tester);
  await tester.pumpAndSettle();
  expect(find.text('显示在其他应用上层？'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('risk-confirm')));
  await tester.pumpAndSettle();
  await settlePhone(tester);
}

bool _switchOn(WidgetTester tester) => tester
    .widget<Switch>(
      find.descendant(of: find.widgetWithText(SettingsSwitchTile, 'App 外显示'), matching: find.byType(Switch)),
    )
    .value;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('nothing without the native side', (tester) async {
    removeOverlayNative();
    await _pump(tester);
    expect(find.text('App 外显示'), findsNothing);
  });

  testWidgets('off: one switch; on: 有事时显示 / 一直显示', (tester) async {
    final native = FakeOverlayNative(permission: 'granted')..install();
    await _pump(tester);
    expect(_switchOn(tester), isFalse);
    expect(find.text('一直显示'), findsNothing);

    await tester.tap(find.text('App 外显示'));
    await settlePhone(tester);
    await tester.pumpAndSettle();
    // Already allowed: nothing to say first.
    expect(find.byType(RiskNoticeSheet), findsNothing);
    expect(native.enabled, isTrue);
    expect(_switchOn(tester), isTrue);
    expect(find.text('有事时显示'), findsOneWidget);

    await tester.tap(find.text('一直显示'));
    await settlePhone(tester);
    expect(native.alwaysShow, isTrue);
  });

  testWidgets('missing companion content explains the disabled choice without downloading', (tester) async {
    final native = FakeOverlayNative(permission: 'granted', enabled: true)..install();
    await _pump(tester);
    final row = tester.widget<SettingsSwitchTile>(find.byKey(const ValueKey('pet-overlay-companion')));
    expect(row.value, isFalse);
    expect(row.onChanged, isNull);
    expect(find.textContaining('手机上还没有运行库'), findsOneWidget);
    expect(native.methods, isNot(contains('configureCompanion')));
  });

  testWidgets('complete local content offers an explicit renderer choice and a way back', (tester) async {
    FakeOverlayNative(permission: 'granted', enabled: true).install();
    await _pump(tester, companionProblem: null);
    final setting = find.byKey(const ValueKey('pet-overlay-companion'));
    final container = ProviderScope.containerOf(tester.element(setting));
    final row = tester.widget<SettingsSwitchTile>(setting);
    expect(row.onChanged, isNotNull);
    row.onChanged!(true);
    await settlePhone(tester);
    expect(container.read(petPrefsProvider).overlayRenderer, PetOverlayRenderer.companion);
    tester.widget<SettingsSwitchTile>(setting).onChanged!(false);
    await settlePhone(tester);
    expect(container.read(petPrefsProvider).overlayRenderer, PetOverlayRenderer.pixel);
  });

  testWidgets('refused: back off, 「未授权」, then the restricted-settings guide', (tester) async {
    final native = FakeOverlayNative(sdk: 34)..install();
    // Tall enough for the whole guide page.
    await _pump(tester, height: 2400);
    await _turnOnThroughNotice(tester);
    expect(native.methods, contains('requestPermission'));
    // Back from system settings without it.
    await leaveAndResume(tester);
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isFalse);
    expect(find.text('未授权'), findsOneWidget);
    expect(find.text('开关点不动'), findsOneWidget);

    await tester.tap(find.text('开关点不动'));
    await tester.pumpAndSettle();
    expect(find.byType(RestrictedSettingsGuidePage), findsOneWidget);
    expect(find.text('侧载的 App 要先放行这一项，悬浮窗开关才点得动'), findsOneWidget);
    expect(find.textContaining('先去「悬浮窗」设置里点一次 DSH Go 的开关'), findsOneWidget);
    expect(find.text('回到「悬浮窗」设置，打开 DSH Go。'), findsOneWidget);
    expect(find.text('去开悬浮窗'), findsOneWidget);
  });

  testWidgets('no restricted-settings row before Android 13 or for a vendor block', (tester) async {
    final native = FakeOverlayNative(sdk: 32)..install();
    await _pump(tester);
    await _turnOnThroughNotice(tester);
    await leaveAndResume(tester);
    expect(find.text('未授权'), findsOneWidget);
    expect(find.text('开关点不动'), findsNothing);
    expect(native.enabled, isFalse);
  });

  testWidgets('the permission is explained once: × stays off, 不再提示 goes straight on next time', (tester) async {
    final native = FakeOverlayNative()..install();
    await _pump(tester);
    await tester.tap(find.text('App 外显示'));
    await tester.pumpAndSettle();
    expect(find.text('显示在其他应用上层？'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(RiskNoticeSheet), matching: find.byTooltip('关闭')));
    await tester.pumpAndSettle();
    expect(native.methods, isNot(contains('requestPermission')));
    expect(native.enabled, isFalse);

    await _turnOnThroughNotice(tester);
    expect(native.methods, contains('requestPermission'));
    await leaveAndResume(tester);
    await tester.pumpAndSettle();

    // 不再提示 was ticked: the next try goes to system settings at once.
    native.calls.clear();
    await tester.tap(find.text('App 外显示'));
    await settlePhone(tester);
    await tester.pumpAndSettle();
    expect(find.byType(RiskNoticeSheet), findsNothing);
    expect(native.methods, contains('requestPermission'));
  });

  testWidgets('今天不再显示 shows while snoozed and 恢复 ends it', (tester) async {
    final native = FakeOverlayNative(permission: 'granted', enabled: true, snoozed: true)..install();
    await _pump(tester);
    expect(find.text('今天不再显示'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    await settlePhone(tester);
    expect(native.snoozed, isFalse);
    expect(find.text('今天不再显示'), findsNothing);
  });

  testWidgets('the overlay guide turns the switch on, opens the setting, and says when done', (tester) async {
    final native = FakeOverlayNative()..install();
    await pumpPhone(tester, const RestrictedSettingsGuidePage(target: RestrictedTarget.overlay));
    expect(find.text('悬浮窗已开好，可以返回了'), findsNothing);
    await tester.ensureVisible(find.text('去开悬浮窗'));
    await tester.tap(find.text('去开悬浮窗'));
    await settlePhone(tester);
    expect(native.enabled, isTrue);
    expect(native.methods, contains('requestPermission'));
    native.permission = 'granted';
    await leaveAndResume(tester);
    expect(find.text('悬浮窗已开好，可以返回了'), findsOneWidget);
    expect(native.enabled, isTrue);
  });

  testWidgets('the accessibility guide is unchanged', (tester) async {
    await pumpPhone(tester, const RestrictedSettingsGuidePage());
    expect(find.text('侧载的 App 要先放行这一项，无障碍开关才点得动'), findsOneWidget);
    expect(find.text('去开无障碍'), findsOneWidget);
    expect(find.textContaining('先去「无障碍」里点一次 DSH 的开关'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden: on, 有事时显示, snoozed ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      FakeOverlayNative(permission: 'granted', enabled: true, snoozed: true).install();
      await _pump(tester, brightness: brightness);
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/overlay_settings_$mode.png'));
    });
  }
}
