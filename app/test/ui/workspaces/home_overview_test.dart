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
  testWidgets(
    'home overview leads with a new session and lists recent ones, newest first',
    (tester) async {
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

      expect(find.byKey(const Key('workspace-overview')), findsOneWidget);
      expect(find.byKey(const Key('overview-new-session')), findsOneWidget);
      final beta = tester.getTopLeft(
        find.byKey(const ValueKey('overview-session-beta')),
      );
      final alpha = tester.getTopLeft(
        find.byKey(const ValueKey('overview-session-alpha')),
      );
      expect(beta.dy, lessThan(alpha.dy));
      expect(find.text('Beta task'), findsOneWidget);
      expect(find.byKey(const Key('overview-previous-sessions')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      hosts.dispose();
      prefs.dispose();
    },
  );

  testWidgets(
    'home overview empty state names Inbox and points to the start card',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = Preferences();
      await prefs.load();
      final peer = testPeer();
      final storage = MemoryStorage([peer]);
      final host = FakeHost(sessions: []);
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

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('No sessions yet'), findsOneWidget);
      expect(find.byKey(const Key('overview-new-session')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      hosts.dispose();
      prefs.dispose();
    },
  );

  testWidgets('home overview opens a recent session', (tester) async {
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
        GoRoute(path: '/home', builder: (_, _) => const SessionWelcome()),
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
    await tester.tap(find.byKey(const ValueKey('overview-session-alpha')));
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
}
