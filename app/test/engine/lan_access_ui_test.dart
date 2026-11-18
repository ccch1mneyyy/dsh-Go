import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/engine/lan_access_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../support/test_fonts.dart';

const _channel = MethodChannel('dsh/runtime');

class _Runtime extends LocalRuntimeController {
  _Runtime(this.wire);
  final Map<String, Object?> wire;
  final calls = <String>[];

  @override
  LocalRuntimeState build() => LocalRuntimeState(loaded: true, status: RuntimeStatus.fromMap(wire));

  @override
  Future<void> stop() async {
    calls.add('stop');
    wire['phase'] = 'installed';
    state = LocalRuntimeState(loaded: true, status: RuntimeStatus.fromMap(wire));
  }

  @override
  Future<void> start() async {
    calls.add('start');
    wire['phase'] = 'running';
    state = LocalRuntimeState(loaded: true, status: RuntimeStatus.fromMap(wire));
  }
}

class _Active extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
  @override
  void select(HostRef host) => state = host;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  Future<_Runtime> pump(WidgetTester tester, Map<String, Object?> wire, {List<MethodCall>? calls}) async {
    final runtime = _Runtime(wire);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls?.add(call);
      if (call.method == 'setLanAccess') wire['lanAccessEnabled'] = (call.arguments as Map)['enabled'];
      return null;
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          runtimeBridgeProvider.overrideWithValue(RuntimeBridge()),
          activeHostProvider.overrideWith(_Active.new),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocale.supported,
          localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
          home: const Scaffold(body: LanAccessSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return runtime;
  }

  testWidgets('enabling confirms, stops, saves and restarts', (tester) async {
    final wire = <String, Object?>{
      'phase': 'installed',
      'installedVersion': 'test-runtime',
      'lanAccessEnabled': false,
    };
    final native = <MethodCall>[];
    final runtime = await pump(tester, wire, calls: native);
    await tester.tap(find.byKey(const ValueKey('lan-access-switch')));
    await tester.pumpAndSettle();
    expect(find.text('局域网访问'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('lan-access-confirm')));
    await tester.pumpAndSettle();
    expect(native.single.method, 'setLanAccess');
    expect((native.single.arguments as Map)['enabled'], true);
    expect(runtime.calls, ['start']);
    expect(wire['lanAccessEnabled'], true);
  });

  testWidgets('disabling a running engine stops, saves and restarts', (tester) async {
    final wire = <String, Object?>{
      'phase': 'running',
      'installedVersion': 'test-runtime',
      'baseUrl': 'http://127.0.0.1:3080',
      'token': 'synthetic-local-token',
      'lanAccessEnabled': true,
      'lanAddress': '192.168.110.71',
      'lanPort': 3080,
      'lanBaseUrl': 'http://192.168.110.71:3080/',
    };
    final native = <MethodCall>[];
    final runtime = await pump(tester, wire, calls: native);
    await tester.tap(find.byKey(const ValueKey('lan-access-switch')));
    await tester.pumpAndSettle();
    expect(native.single.method, 'setLanAccess');
    expect((native.single.arguments as Map)['enabled'], false);
    expect(runtime.calls, ['stop', 'start']);
    expect(wire['lanAccessEnabled'], false);
  });

  testWidgets('running LAN status copies the short login URL without showing the token', (tester) async {
    final wire = <String, Object?>{
      'phase': 'running',
      'installedVersion': 'test-runtime',
      'baseUrl': 'http://127.0.0.1:3080',
      'token': 'synthetic-local-token',
      'lanAccessEnabled': true,
      'lanAddress': '192.168.110.71',
      'lanPort': 3080,
      'lanBaseUrl': 'http://192.168.110.71:3080/',
    };
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(tester, wire);
    expect(find.textContaining('synthetic-local-token'), findsNothing);
    expect(find.byKey(const ValueKey('lan-access-copy')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lan-access-copy')));
    await tester.pumpAndSettle();
    expect(copied, 'http://192.168.110.71:3080/login');
  });
}
