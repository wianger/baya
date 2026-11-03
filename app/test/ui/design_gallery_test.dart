// Renders the main screens to PNG for design review:
//   BAYA_PREVIEW_DIR=<dir> [BAYA_PREVIEW_THEME=light] flutter test test/ui/design_gallery_test.dart
// Skipped otherwise.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/pairing/backed_up_identity_store.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/onboarding/onboarding_page.dart';
import 'package:app/ui/onboarding/viewmodels/onboarding_viewmodel.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:app/ui/workspaces/new_session_page.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/states/new_session_state.dart';
import 'package:app/ui/workspaces/viewmodels/new_session_viewmodel.dart';
import 'package:baya_identity/baya_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../support/acp_harness.dart';
import 'workspaces/new_session_viewmodel_test.dart' show FakeWorkspaces;

Future<void> _fonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest) {
      final loader = FontLoader(entry['family'] as String);
      for (final face in entry['fonts'] as List) {
        loader.addFont(rootBundle.load(face['asset'] as String));
      }
      await loader.load();
    }
  });
}

class _Updates extends UpdateBannerViewModel {
  _Updates()
    : super(
        _NoChecker(),
        _NoStore(),
        _NoOpener(),
        currentVersion: '2.2.0',
        currentBuildNumber: 92,
        enabled: false,
      );
}

class _NoChecker implements UpdateChecker {
  @override
  Future<UpdateInfo?> fetchLatest() async => null;
}

class _NoStore implements DismissedUpdateStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _NoOpener implements UrlOpener {
  @override
  Future<bool> open(String url) async => false;
}

void main() {
  final output = Platform.environment['BAYA_PREVIEW_DIR'];
  final light = Platform.environment['BAYA_PREVIEW_THEME'] == 'light';
  final theme = (light ? buildLightTheme() : buildDarkTheme()).copyWith(
    platform: TargetPlatform.android,
  );

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget page, {
    List<SingleChildWidget> providers = const [],
    Size size = const Size(412, 892),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MultiProvider(
          providers: providers,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: page,
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('design gallery', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _fonts(tester);
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();

    final desktop = testPeer(seed: 1, name: 'studio (WSL)');
    final laptop = testPeer(seed: 2, name: 'studio (Windows)');
    final storage = MemoryStorage([desktop, laptop]);
    final hosts = testHostsFor(storage, {
      desktop.remoteEpk: FakeHost(
        sessions: [
          testSession(
            id: 'a',
            title: 'Fix the login redirect',
            cwd: '/home/me/web',
            working: true,
            updatedAt: DateTime.utc(2026, 11, 3, 9),
          ),
          testSession(
            id: 'b',
            title: 'Add rate limiting to the API',
            cwd: '/home/me/api',
            agent: 'codex',
            agentName: 'Codex',
            updatedAt: DateTime.utc(2026, 11, 3, 8),
          ),
          testSession(
            id: 'c',
            title: 'Write the release notes',
            cwd: '/home/me/web',
            agent: 'pi',
            agentName: 'Pi',
            updatedAt: DateTime.utc(2026, 11, 2, 18),
          ),
        ],
      ),
    });
    await hosts.start();
    await pumpOnline(tester, hosts);
    final home = HomeViewModel(hosts, storage, prefs);
    final selection = SessionSelection();
    final common = <SingleChildWidget>[
      ChangeNotifierProvider<Preferences>.value(value: prefs),
      ChangeNotifierProvider<HomeViewModel>.value(value: home),
      ChangeNotifierProvider<SessionSelection>.value(value: selection),
      ChangeNotifierProvider<Hosts>.value(value: hosts),
    ];

    await shoot(
      tester,
      'home',
      const SessionShell(child: SessionWelcome()),
      providers: common,
    );
    await shoot(
      tester,
      'sidebar',
      const Scaffold(body: SafeArea(child: SessionSidebar())),
      providers: common,
    );
    await shoot(
      tester,
      'tablet',
      const SessionShell(child: SessionWelcome()),
      providers: common,
      size: const Size(1280, 800),
    );

    final newSession = NewSessionViewModel(
      FakeWorkspaces(),
      launch: const NewSessionLaunch(
        workspaces: [
          WorkspaceGroup(
            workspaceKey: 'computer:workspace:web',
            deviceId: 'computer',
            label: 'Web',
            subtitle: '2 sessions',
          ),
        ],
        selectedWorkspace: 'computer:workspace:web',
      ),
    );
    await shoot(
      tester,
      'new-session',
      const NewSessionPage(),
      providers: [
        ...common,
        ChangeNotifierProvider<NewSessionViewModel>.value(value: newSession),
      ],
    );

    await shoot(
      tester,
      'settings',
      const SettingsPage(),
      providers: [
        ...common,
        ChangeNotifierProvider(
          create: (_) => SettingsViewModel(storage, prefs, hosts),
        ),
        ChangeNotifierProvider<UpdateBannerViewModel>(
          create: (_) => _Updates(),
        ),
      ],
    );

    final identity = BackedUpOwnerIdentityStore(InMemoryOwnerIdentityStore());
    final bridge = OwnerIdentityBridge(identity, storage);
    await bridge.boot();
    await shoot(
      tester,
      'onboarding',
      const OnboardingPage(),
      providers: [
        ...common,
        ChangeNotifierProvider<BackedUpOwnerIdentityStore>.value(
          value: identity,
        ),
        ChangeNotifierProvider(create: (_) => OnboardingViewModel(prefs)),
        ChangeNotifierProvider(
          create: (_) => PairingViewModel(
            storage,
            ({required endpoint, required hostKey, required identity}) =>
                throw UnimplementedError(),
            prefs,
            bridge,
          ),
        ),
      ],
    );

    home.dispose();
    hosts.dispose();
  }, skip: output == null);
}
