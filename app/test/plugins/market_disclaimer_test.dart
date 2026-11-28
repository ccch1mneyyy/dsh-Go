import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/links/plugin_links.dart';
import 'package:dsh_app/ui/plugins/installed_tab.dart';
import 'package:dsh_app/ui/plugins/market_disclaimer.dart';
import 'package:dsh_app/ui/plugins/market_tab.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

Finder get _notice => find.text('插件市场风险提示与免责声明');
Finder get _market => find.byType(MarketSliver, skipOffstage: false);

Future<void> _choose(WidgetTester tester, String label) async {
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    SharedPreferences.setMockInitialValues({});
  });

  Widget app(Widget home) {
    final carrier = FakePluginCarrier();
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    return testApp(home, overrides: pluginOverrides(fakeHost(client), bypassMarketDisclaimer: false));
  }

  testWidgets('initial market waits for consent; declining returns to installed and lets users retry', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(app(const PluginsScreen(initialTab: PluginsTab.market)));
    expect(_market, findsNothing);
    await tester.pumpAndSettle();
    expect(_notice, findsOneWidget);
    expect(_market, findsNothing);

    await _choose(tester, '暂不进入');
    expect(_notice, findsNothing);
    expect(find.byType(InstalledPluginsSliver), findsOneWidget);
    expect(_market, findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(marketDisclaimerAcceptedKey), isFalse);

    await tester.tap(find.text('插件市场'));
    await tester.pumpAndSettle();
    expect(_notice, findsOneWidget);
    expect(_market, findsNothing);
    await _choose(tester, '我已阅读，进入市场');
    expect(_notice, findsNothing);
    expect(_market, findsOneWidget);
  });

  testWidgets('switching from installed persists consent for a new screen and ProviderScope', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(app(const PluginsScreen()));
    await tester.pumpAndSettle();
    expect(_notice, findsNothing);
    expect(find.byType(InstalledPluginsSliver), findsOneWidget);

    await tester.tap(find.text('插件市场'));
    await tester.pump();
    expect(_market, findsNothing);
    await tester.pumpAndSettle();
    expect(_notice, findsOneWidget);
    expect(_market, findsNothing);
    await _choose(tester, '我已阅读，进入市场');
    expect(_notice, findsNothing);
    expect(_market, findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getBool(marketDisclaimerAcceptedKey), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(const PluginsScreen(initialTab: PluginsTab.market)));
    await tester.pumpAndSettle();
    expect(_notice, findsNothing);
    expect(_market, findsOneWidget);
  });

  testWidgets('declining a plugin market deep link never opens its detail sheet', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(app(const Scaffold(body: Text('首页'))));
    final context = tester.element(find.text('首页'));
    final opening = openMarketPluginLink(context, Uri.parse(marketPluginLink('novel-writer')));
    await tester.pumpAndSettle();
    expect(_notice, findsOneWidget);
    final detail = find.byType(MarketPluginSheet, skipOffstage: false);
    expect(detail, findsNothing);

    await _choose(tester, '暂不进入');
    expect(await opening, isTrue);
    expect(_notice, findsNothing);
    expect(detail, findsNothing);
    expect(find.text('首页'), findsOneWidget);
  });
}
