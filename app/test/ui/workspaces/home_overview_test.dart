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
    'home overview summarizes the workspace without repeating its session list',
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
        ChangeNotifierProvider.value(
          value: vm,
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const SessionWelcome(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('workspace-overview')), findsOneWidget);
      expect(find.text('CURRENT WORKSPACE'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('overview-sessions')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('overview-focus-session')),
          matching: find.text('Beta task'),
        ),
        findsOneWidget,
      );
      expect(find.text('Alpha task'), findsNothing);
      expect(find.byKey(const Key('overview-new-session')), findsNothing);
      expect(find.text('New session'), findsNothing);
      expect(find.text('Create workspace'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      hosts.dispose();
      prefs.dispose();
    },
  );

  testWidgets(
    'home overview empty state uses Inbox without creating sessions',
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
        ChangeNotifierProvider.value(
          value: vm,
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const SessionWelcome(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('No sessions yet'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Create'), findsNothing);
      expect(find.text('New session'), findsNothing);
      expect(find.text('Create workspace'), findsNothing);
      expect(find.byKey(const Key('overview-new-session')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      hosts.dispose();
      prefs.dispose();
    },
  );

  testWidgets(
    'home overview opens an earlier session from the current workspace',
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
      await tester.tap(find.byKey(const Key('overview-previous-sessions')));
      await tester.pumpAndSettle();

      final sheet = find.byKey(const Key('previous-sessions-sheet'));
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text('Previous task')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('Latest task')),
        findsNothing,
      );

      await tester.tap(
        find.descendant(of: sheet, matching: find.text('Previous task')),
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
    },
  );
}
