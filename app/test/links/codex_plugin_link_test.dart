// Incoming plugin links and open sheets respect the selected backend.
import 'dart:async';

import 'package:codex_backend/codex_backend.dart';
import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/codex_backend/test/support/fake_codex.dart' as codex;
import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';

class _BackendMode extends Notifier<bool> {
  @override
  bool build() => true;
  void select(bool dsh) => state = dsh;
}

final _backendMode = NotifierProvider<_BackendMode, bool>(_BackendMode.new);

void main() {
  testWidgets('Codex backend does not offer DSH plugin installation via incoming links', (tester) async {
    final wire = codex.Fake();
    final client = CodexChatClient(wire);
    await tester.runAsync(client.ready);
    final links = AppLinks();
    final router = LinkRouter(links.links, grace: Duration.zero);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: LinkHost()),
        overrides: [
          ...pluginOverrides(
            fakeHost(client, kind: HostKind.ssh, label: 'Demo Codex'),
            official: () async => officialFixtureMarket(),
          ),
          advancedBackendProvider.overrideWithValue(false),
          linkRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    await tester.pump();
    links.add(Uri.parse('dshgo://go.dshtui.com/p/%40dsh-go%2Fmedia'));
    await tester.pumpAndSettle();
    final sheet = find.byType(MarketPluginSheet).evaluate().length;
    final install = find.text('获取安装命令').evaluate().length;
    expect(find.text('此功能仅适用于 DSH 插件，请先切换到 DSH 主机。'), findsOneWidget);
    expect(install, 0);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    links.dispose();
    await tester.runAsync(client.close);
    expect(sheet, 0, reason: 'DSH-only entry should respect the selected Codex backend');
  });

  testWidgets('switching to Codex during plugin lookup does not open a DSH sheet', (tester) async {
    final carrier = FakePluginCarrier();
    final client = DshClient.withCarrier(carrier);
    final catalog = Completer<MarketCatalog>();
    final links = AppLinks();
    final router = LinkRouter(links.links, grace: Duration.zero);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: LinkHost()),
        overrides: [
          ...pluginOverrides(fakeHost(client), official: () => catalog.future),
          advancedBackendProvider.overrideWith((ref) => ref.watch(_backendMode)),
          linkRouterProvider.overrideWithValue(router),
        ],
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(LinkHost)));
    links.add(Uri.parse('dshgo://go.dshtui.com/p/%40dsh-go%2Fmedia'));
    await tester.pump();
    container.read(_backendMode.notifier).select(false);
    catalog.complete(officialFixtureMarket());
    await tester.pumpAndSettle();
    expect(find.byType(MarketPluginSheet), findsNothing);
    expect(find.text('此功能仅适用于 DSH 插件，请先切换到 DSH 主机。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    links.dispose();
    await tester.runAsync(client.close);
  });

  for (final installed in [false, true]) {
    testWidgets('${installed ? "installed" : "market"} sheet disables actions when backend changes', (tester) async {
      final carrier = FakePluginCarrier()..handlers['pluginManager/listBundles'] = (_) => sampleBundles;
      final client = DshClient.withCarrier(carrier);
      final bundle = PluginBundle.fromJson(sampleBundles.first);
      final Widget sheet = installed
          ? BundleSheet(name: bundle.name, initial: bundle)
          : MarketPluginSheet(entry: officialFixtureMarket().byName['@dsh-go/media']!);
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(body: sheet),
          overrides: [
            ...pluginOverrides(fakeHost(client)),
            advancedBackendProvider.overrideWith((ref) => ref.watch(_backendMode)),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final finder = installed ? find.byType(BundleSheet) : find.byType(MarketPluginSheet);
      final container = ProviderScope.containerOf(tester.element(finder));
      expect(find.text('此功能仅适用于 DSH 插件，请先切换到 DSH 主机。'), findsNothing);
      container.read(_backendMode.notifier).select(false);
      await tester.pumpAndSettle();
      expect(find.text('此功能仅适用于 DSH 插件，请先切换到 DSH 主机。'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.close);
    });
  }
}
