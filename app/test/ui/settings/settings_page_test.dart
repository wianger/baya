import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/acp_harness.dart';

class _Storage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

class _SecureStorage implements FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SettingsFixture {
  _SettingsFixture()
    : storage = _Storage(),
      prefs = Preferences(_SecureStorage()) {
    hosts = testHosts(MemoryStorage(), FakeHost());
    vm = SettingsViewModel(storage, prefs, hosts);
  }

  final _Storage storage;
  final Preferences prefs;
  late final Hosts hosts;
  late final SettingsViewModel vm;

  Widget build() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsViewModel>.value(value: vm),
        ChangeNotifierProvider<Preferences>.value(value: prefs),
      ],
      child: MaterialApp(theme: buildLightTheme(), home: const SettingsPage()),
    );
  }

  void dispose() {
    vm.dispose();
    hosts.dispose();
    prefs.dispose();
  }
}

Future<_SettingsFixture> _pumpSettings(WidgetTester tester) async {
  final fixture = _SettingsFixture();
  await tester.pumpWidget(fixture.build());
  await tester.pump();
  return fixture;
}

Future<void> _disposeSettings(
  WidgetTester tester,
  _SettingsFixture fixture,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  fixture.dispose();
  await tester.pump();
}

void main() {
  testWidgets('display details open when providers live on the route only', (
    tester,
  ) async {
    // Mirrors production: Preferences is app-level (above MaterialApp) while
    // SettingsViewModel is created by the `/settings` route. Pushed detail
    // routes are siblings in the navigator, so they must re-inject the
    // ViewModel themselves or they throw on first read.
    final fixture = _SettingsFixture();
    await tester.pumpWidget(
      ChangeNotifierProvider<Preferences>.value(
        value: fixture.prefs,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: ChangeNotifierProvider<SettingsViewModel>.value(
            value: fixture.vm,
            child: const SettingsPage(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('settings-display')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme-selector')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposeSettings(tester, fixture);
  });

  testWidgets('settings home exposes one entry per section', (tester) async {
    final fixture = await _pumpSettings(tester);

    expect(find.text('Pairings'), findsNothing);
    expect(find.text('Add new pairing'), findsNothing);
    expect(find.byKey(const Key('settings-display')), findsOneWidget);
    expect(find.byKey(const Key('settings-about')), findsOneWidget);

    expect(find.byKey(const Key('theme-selector')), findsNothing);
    expect(find.byKey(const Key('font-scale-selector')), findsNothing);
    expect(find.byKey(const Key('hide-tool-calls')), findsNothing);

    await _disposeSettings(tester, fixture);
  });

  testWidgets('display details open from the single display entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await _pumpSettings(tester);

    await tester.tap(find.byKey(const Key('settings-display')));
    await tester.pumpAndSettle();

    expect(find.text('Display and conversation'), findsWidgets);
    expect(find.byKey(const Key('theme-selector')), findsOneWidget);
    expect(find.byKey(const Key('font-scale-selector')), findsOneWidget);
    expect(find.byKey(const Key('hide-tool-calls')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposeSettings(tester, fixture);
  });
}
