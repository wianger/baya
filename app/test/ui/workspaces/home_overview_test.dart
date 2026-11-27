import 'package:app/acp/acp.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../support/acp_harness.dart';

void main() {
  testWidgets('home shows only the mark and the wordmark', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();
    final peer = testPeer();
    final storage = MemoryStorage([peer]);
    final host = FakeHost(
      sessions: [
        testSession(
          id: 'alpha',
          cwd: '/code/project',
          title: 'Alpha task',
          updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        ),
        testSession(
          id: 'beta',
          cwd: '/code/project',
          title: 'Beta task',
          updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 2),
        ),
      ],
    );
    final hosts = testHosts(storage, host);
    await hosts.start();
    final vm = HomeViewModel(hosts, storage, prefs);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vm),
          ChangeNotifierProvider<Preferences>.value(value: prefs),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const SessionWelcome(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // DeepSeek's home: the greeting and the composer, no session lists.
    expect(find.byKey(const Key('workspace-overview')), findsOneWidget);
    expect(find.byKey(const Key('overview-wordmark')), findsOneWidget);
    expect(find.byKey(const Key('overview-new-session')), findsNothing);
    expect(find.text('Beta task'), findsNothing);
    expect(find.text('Alpha task'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    hosts.dispose();
    prefs.dispose();
  });

  testWidgets('the drawer opens a session', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();
    final peer = testPeer();
    final storage = MemoryStorage([peer]);
    final host = FakeHost(
      sessions: [
        testSession(
          id: 'alpha',
          cwd: '/code/project',
          title: 'Previous task',
          updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        ),
        testSession(
          id: 'beta',
          cwd: '/code/project',
          title: 'Latest task',
          updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 2),
        ),
      ],
    );
    final hosts = testHosts(storage, host);
    await hosts.start();
    final vm = HomeViewModel(hosts, storage, prefs);
    final selection = SessionSelection();
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: SessionSidebar()),
        ),
        GoRoute(
          path: '/chat',
          builder: (_, _) => const Scaffold(body: Text('Opened chat route')),
        ),
      ],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vm),
          ChangeNotifierProvider.value(value: selection),
          ChangeNotifierProvider<Preferences>.value(value: prefs),
        ],
        child: MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final alpha = vm.allItems.firstWhere((item) => item.sessionId == 'alpha');

    expect(find.text('Latest task'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('session-row-${peer.remoteEpk}-alpha')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Opened chat route'), findsOneWidget);
    expect(selection.matches(alpha.peer.remoteEpk, alpha.sessionId), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    selection.dispose();
    vm.dispose();
    hosts.dispose();
    prefs.dispose();
  });

  testWidgets('holding a session in the drawer opens its actions', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();
    final peer = testPeer();
    final storage = MemoryStorage([peer]);
    final host = FakeHost(
      sessions: [
        testSession(
          id: 'alpha',
          cwd: '/code/project',
          title: 'Alpha task',
          updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        ),
        testSession(
          id: 'beta',
          cwd: '/code/project',
          title: 'Beta task',
          updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 2),
        ),
      ],
    );
    final hosts = testHosts(storage, host);
    await hosts.start();
    final vm = HomeViewModel(hosts, storage, prefs);
    final selection = SessionSelection();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vm),
          ChangeNotifierProvider<Preferences>.value(value: prefs),
          ChangeNotifierProvider.value(value: selection),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const Scaffold(body: SessionSidebar()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(ValueKey('session-row-${peer.remoteEpk}-alpha')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-action-rename')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-action-pin')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    hosts.dispose();
    prefs.dispose();
    selection.dispose();
  });

  for (final screen in [true, false]) {
    testWidgets('remote control is offered only where the screen can be '
        '(${screen ? 'Windows host' : 'other host'})', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = Preferences();
      await prefs.load();
      final storage = MemoryStorage([testPeer()]);
      final hosts = testHosts(storage, FakeHost(screen: screen));
      await hosts.start();
      final vm = HomeViewModel(hosts, storage, prefs);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: vm),
            ChangeNotifierProvider<Preferences>.value(value: prefs),
            ChangeNotifierProvider.value(value: SessionSelection()),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const Scaffold(body: SessionSidebar()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('drawer-remote-control')),
        screen ? findsOneWidget : findsNothing,
      );
      expect(find.byKey(const Key('overview-terminals')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      hosts.dispose();
      prefs.dispose();
    });
  }

  testWidgets('a session in a herdr pane is filed under its herdr workspace', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();
    final peer = testPeer();
    final storage = MemoryStorage([peer]);
    final host = FakeHost(
      sessions: [
        const SessionSummary(
          sessionId: 'herdr-w1-p2',
          cwd: '/home/me/carve',
          title: 'Context sandbox',
          agent: 'claude',
          agentName: 'Claude Code',
          paneStatus: 'idle',
          paneWorkspace: 'carve',
        ),
        testSession(id: 'own'),
      ],
    );
    final hosts = testHosts(storage, host);
    await hosts.start();
    final vm = HomeViewModel(hosts, storage, prefs);
    await tester.pumpAndSettle();

    final item = vm.allItems.firstWhere((i) => i.sessionId == 'herdr-w1-p2');
    expect(vm.workspaceLabel(vm.workspaceKeyFor(item)), 'carve');
    final own = vm.allItems.firstWhere((i) => i.sessionId == 'own');
    // Nobody filed it: its folder's workspace.
    expect(vm.workspaceLabel(vm.workspaceKeyFor(own)), 'app');

    vm.dispose();
    hosts.dispose();
    prefs.dispose();
  });
}
