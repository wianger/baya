import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/widgets/scope_switchers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../support/acp_harness.dart';

void main() {
  testWidgets('device and workspace pickers size to their visible rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<double> measureDevicePicker(int count) async {
      final devices = {
        for (var index = 0; index < count; index++)
          'computer-$index': 'Computer $index',
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: DeviceSwitcher(
              devices: devices,
              selected: 'computer-0',
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('device-switch')));
      await tester.pumpAndSettle();
      final height = tester
          .getSize(find.byKey(const Key('device-switcher-sheet')))
          .height;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      return height;
    }

    Future<double> measureWorkspacePicker(int count) async {
      final workspaces = {
        for (var index = 0; index < count; index++)
          'pc:workspace:$index': '$index sessions',
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: WorkspaceSwitcher(
              workspaces: workspaces,
              labels: {
                for (var index = 0; index < count; index++)
                  'pc:workspace:$index': 'Workspace $index',
              },
              selected: 'pc:workspace:0',
              hasDevice: true,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('workspace-switch')));
      await tester.pumpAndSettle();
      final height = tester
          .getSize(find.byKey(const Key('workspace-switcher-sheet')))
          .height;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      return height;
    }

    final compactDevices = await measureDevicePicker(2);
    final expandedDevices = await measureDevicePicker(12);
    expect(compactDevices, lessThan(320));
    expect(expandedDevices, greaterThan(compactDevices));
    expect(expandedDevices, lessThanOrEqualTo(844 * .86));

    final compactWorkspaces = await measureWorkspacePicker(1);
    final expandedWorkspaces = await measureWorkspacePicker(10);
    expect(compactWorkspaces, lessThan(320));
    expect(expandedWorkspaces, greaterThan(compactWorkspaces));
    expect(expandedWorkspaces, lessThanOrEqualTo(844 * .86));
  });

  testWidgets('device switcher moves add, rename and delete into the sheet', (
    tester,
  ) async {
    String? switched;
    var renameCalls = 0;
    var deleteCalls = 0;
    var addCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: DeviceSwitcher(
            devices: const {
              'computer-a': 'Computer A',
              'computer-b': 'Computer B',
            },
            selected: 'computer-a',
            onSelected: (value) => switched = value,
            onAdd: () => addCalls++,
            onRename: (epk) async {
              renameCalls++;
              return true;
            },
            onDelete: (epk) async {
              deleteCalls++;
              return true;
            },
          ),
        ),
      ),
    );

    // The whole card opens the sheet now — no precise tap on the trailing icon.
    await tester.tap(find.text('Computer A'));
    await tester.pumpAndSettle();
    expect(find.text('Switch device'), findsOneWidget);
    final deviceSheet = find.byKey(const Key('device-switcher-sheet'));
    final addButton = find.byKey(const Key('device-add'));
    expect(
      tester.getRect(deviceSheet).right - tester.getRect(addButton).right,
      greaterThanOrEqualTo(20),
    );
    expect(switched, isNull);
    expect(renameCalls, 0);
    expect(deleteCalls, 0);

    await tester.tap(find.byKey(const Key('device-rename-computer-a')));
    await tester.pumpAndSettle();
    expect(renameCalls, 1);
    expect(deleteCalls, 0);

    await tester.tap(find.byKey(const Key('device-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-delete-computer-b')));
    await tester.pumpAndSettle();
    expect(deleteCalls, 1);

    await tester.tap(find.byKey(const Key('device-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-add')));
    await tester.pumpAndSettle();
    expect(addCalls, 1);

    await tester.tap(find.byKey(const Key('device-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Computer B'));
    await tester.pumpAndSettle();
    expect(switched, 'computer-b');
  });

  testWidgets('workspace switcher adds, renames and deletes from the sheet', (
    tester,
  ) async {
    var created = 0;
    var deleted = 0;
    var renamed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: WorkspaceSwitcher(
            workspaces: const {
              'pc:workspace:alpha': 'one session',
              'pc:workspace:beta': 'two sessions',
            },
            labels: const {
              'pc:workspace:alpha': 'Alpha',
              'pc:workspace:beta': 'Beta',
            },
            selected: 'pc:workspace:alpha',
            hasDevice: true,
            onSelected: (_) {},
            onCreate: () => created++,
            onRename: (_, _) async {
              renamed++;
              return true;
            },
            canDelete: (_) => true,
            onDelete: (_) async {
              deleted++;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('workspace-switch')));
    await tester.pumpAndSettle();
    expect(find.text('Switch workspace'), findsOneWidget);
    final workspaceSheet = find.byKey(const Key('workspace-switcher-sheet'));
    final workspaceAdd = find.byKey(const Key('workspace-add'));
    expect(
      tester.getRect(workspaceSheet).right - tester.getRect(workspaceAdd).right,
      greaterThanOrEqualTo(20),
    );

    await tester.tap(find.byKey(const Key('workspace-add')));
    await tester.pumpAndSettle();
    expect(created, 1);

    await tester.tap(find.byKey(const Key('workspace-switch')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workspace-rename-pc:workspace:beta')),
      findsOne,
    );
    await tester.tap(
      find.byKey(const Key('workspace-rename-pc:workspace:beta')),
    );
    await tester.pumpAndSettle();
    expect(renamed, 1);

    await tester.tap(find.byKey(const Key('workspace-switch')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('workspace-delete-pc:workspace:beta')),
    );
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });

  testWidgets('workspace switcher fallback labels use the logical id', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: WorkspaceSwitcher(
            workspaces: const {
              'pc:workspace:release': '2 sessions · 2 folders',
            },
            selected: 'pc:workspace:release',
            hasDevice: true,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('workspace-switch')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('workspace-choice-pc:workspace:release')),
        matching: find.text('release'),
      ),
      findsOneWidget,
    );
    expect(find.text('2 sessions · 2 folders'), findsOneWidget);
  });

  testWidgets('Inbox cannot be deleted from the workspace switcher', (
    tester,
  ) async {
    const inbox = 'pc:workspace:inbox';
    const custom = 'pc:workspace:release';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: WorkspaceSwitcher(
            workspaces: const {inbox: '', custom: '2 sessions'},
            labels: const {inbox: 'Inbox', custom: 'Release'},
            selected: inbox,
            hasDevice: true,
            onSelected: (_) {},
            canDelete: (key) => !isInboxWorkspace(key),
            onDelete: (_) async => true,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('workspace-switch')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-delete-$inbox')), findsNothing);
    expect(find.byKey(const ValueKey('workspace-delete-$custom')), findsOne);
  });

  testWidgets('empty workspace switcher uses a compact actionable row', (
    tester,
  ) async {
    var created = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: WorkspaceSwitcher(
            workspaces: const {},
            selected: null,
            hasDevice: true,
            onSelected: (_) {},
            onCreate: () => created++,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('workspace-switch')));
    await tester.pumpAndSettle();

    final sheet = find.byKey(const Key('workspace-switcher-sheet'));
    final emptyRow = find.byKey(const Key('workspace-empty-create'));
    expect(sheet, findsOneWidget);
    expect(emptyRow, findsOneWidget);
    expect(find.byIcon(LucideIcons.plus), findsOneWidget);
    expect(
      tester.getRect(sheet).right -
          tester.getRect(find.byKey(const Key('workspace-add'))).right,
      greaterThanOrEqualTo(20),
    );
    expect(
      find.descendant(of: sheet, matching: find.text('No workspaces yet')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text('Create one to group sessions from any folders.'),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(emptyRow).height, lessThan(140));

    await tester.tap(find.byKey(const Key('workspace-add')));
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(sheet, findsNothing);
  });

  testWidgets(
    'workspace control replaces status chips and delete removes the session on the computer',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = Preferences();
      await prefs.load();
      final peer = testPeer();
      final betaWorkspace = workspaceKey(peer.remoteEpk, 'beta');
      await prefs.setWorkspaceName(betaWorkspace, 'beta');
      await prefs.setSessionWorkspace(peer.remoteEpk, 'beta', betaWorkspace);
      await prefs.setSelectedWorkspace(inboxWorkspaceKey(peer.remoteEpk));
      final storage = MemoryStorage([peer]);
      final host = FakeHost(
        sessions: [
          testSession(
            id: 'alpha',
            cwd: '/code/alpha',
            title: 'Alpha task',
            updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
          testSession(
            id: 'beta',
            cwd: '/code/beta',
            title: 'Beta task',
            updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
        ],
      );
      final hosts = testHosts(storage, host);
      await hosts.start();
      final selection = SessionSelection();
      final vm = HomeViewModel(hosts, storage, prefs);
      var cleaned = false;
      Future<void> cleanup() async {
        if (cleaned) return;
        cleaned = true;
        vm.dispose();
        hosts.dispose();
        prefs.dispose();
        selection.dispose();
      }

      addTearDown(cleanup);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: vm),
            ChangeNotifierProvider.value(value: selection),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const Scaffold(
              body: SizedBox(width: 330, child: SessionSidebar()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('All'), findsNothing);
      expect(find.textContaining('Working'), findsNothing);
      expect(find.byType(AppMark), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Baya')).style?.fontFamily,
        'Pinyon Script',
      );
      // Claude-style footer: settings circle + primary New session pill.
      final settings = find.byKey(const Key('sidebar-settings'));
      expect(settings, findsOneWidget);
      expect(tester.getSize(settings), const Size(48, 48));
      expect(find.byKey(const Key('sidebar-new-session')), findsOneWidget);
      expect(find.text('New session'), findsOneWidget);
      // The pill keeps to the bottom-right corner, 16 from the edge.
      expect(
        tester.getRect(find.byKey(const Key('sidebar-new-session'))).right,
        330 - 16,
      );
      // Search lives behind the header circle, not in an always-open field.
      expect(find.byKey(const Key('sidebar-search-field')), findsNothing);
      await tester.tap(find.byKey(const Key('sidebar-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sidebar-search-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('sidebar-search-field')),
        'Beta',
      );
      await tester.pumpAndSettle();
      expect(find.text('Alpha task'), findsNothing);
      await tester.tap(find.byKey(const Key('sidebar-search-close')));
      await tester.pumpAndSettle();
      expect(find.text('Alpha task'), findsOneWidget);
      expect(find.text('Beta task'), findsNothing);
      await tester.tap(find.byKey(const Key('workspace-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta').last);
      await tester.pumpAndSettle();
      expect(find.text('Beta task'), findsOneWidget);
      expect(find.text('Alpha task'), findsNothing);
      expect(prefs.selectedWorkspace, betaWorkspace);
      // Each row's ⋯ opens the session sheet: rename, and delete confirmed
      // inside the sheet.
      final betaMore = find.byKey(
        ValueKey('session-more-${peer.remoteEpk}-beta'),
      );
      await tester.ensureVisible(betaMore);
      await tester.tap(betaMore);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-action-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-delete-confirm')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-delete-confirm')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('session-action-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Renamed Beta',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Renamed Beta'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sidebar-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sidebar-search-field')),
        'Renamed',
      );
      await tester.pumpAndSettle();
      expect(find.text('Renamed Beta'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sidebar-search-close')));
      await tester.pumpAndSettle();

      final renamedMore = find.byKey(
        ValueKey('session-more-${peer.remoteEpk}-beta'),
      );
      await tester.ensureVisible(renamedMore);
      await tester.tap(renamedMore);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-action-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('session-delete-confirm-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-sheet')), findsNothing);
      // Deleting removes the session on the computer, which tells every phone.
      expect(host.calls.last.method, 'session/delete');
      expect(vm.allItems.map((item) => item.sessionId), ['alpha']);
      await tester.pumpWidget(const SizedBox.shrink());
      await cleanup();
      await tester.pump();
    },
  );
}
