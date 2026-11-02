import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/widgets/scope_switchers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../support/phone_controls.dart';

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
    expect(expandedDevices, lessThanOrEqualTo(844 * .7));

    final compactWorkspaces = await measureWorkspacePicker(1);
    final expandedWorkspaces = await measureWorkspacePicker(10);
    expect(compactWorkspaces, lessThan(320));
    expect(expandedWorkspaces, greaterThan(compactWorkspaces));
    expect(expandedWorkspaces, lessThanOrEqualTo(844 * .72));
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
    await tester.drag(find.text('Computer B'), const Offset(-500, 0));
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

  testWidgets('workspace switcher adds from a circle and deletes on swipe', (
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
      greaterThanOrEqualTo(28),
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
    await tester.drag(find.text('Beta'), const Offset(-500, 0));
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

  testWidgets('Inbox cannot be swiped out of the workspace switcher', (
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

    final inboxRow = tester.widget<Dismissible>(
      find.byKey(const ValueKey('workspace-row-$inbox')),
    );
    final customRow = tester.widget<Dismissible>(
      find.byKey(const ValueKey('workspace-row-$custom')),
    );
    expect(inboxRow.direction, DismissDirection.none);
    expect(customRow.direction, DismissDirection.endToStart);
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
      greaterThanOrEqualTo(28),
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

    await tester.tap(emptyRow);
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(sheet, findsNothing);
  });

  testWidgets(
    'workspace control replaces status chips and delete persists across room refresh',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = Preferences();
      await prefs.load();
      final peer = phoneTestPeer(), channel = PhoneTestChannel();
      final betaWorkspace = workspaceKey(peer.remoteEpk, 'beta');
      await prefs.setWorkspaceName(betaWorkspace, 'beta');
      await prefs.setSessionWorkspace(peer.remoteEpk, 'beta', betaWorkspace);
      await prefs.setSelectedWorkspace(inboxWorkspaceKey(peer.remoteEpk));
      final storage = PhoneTestStorage([peer]);
      final conn = ConnectionManager(
        storage: storage,
        factory: (_, _) async => channel,
        emitDebounce: Duration.zero,
      );
      final selection = SessionSelection();
      conn.adopt(channel, peer);
      final vm = HomeViewModel(storage, prefs, conn);
      var cleaned = false;
      Future<void> cleanup() async {
        if (cleaned) return;
        cleaned = true;
        vm.dispose();
        conn.dispose();
        prefs.dispose();
        selection.dispose();
        await channel.disposeStreams();
      }

      addTearDown(cleanup);
      channel.control.add(
        RoomAnnounced(
          peer: peer.remoteEpk,
          room: RoomInfo(
            roomId: 'alpha',
            name: 'Alpha task',
            cwd: '/code/alpha',
            startedAt: 1,
          ),
        ),
      );
      channel.control.add(
        RoomAnnounced(
          peer: peer.remoteEpk,
          room: RoomInfo(
            roomId: 'beta',
            name: 'Beta task',
            cwd: '/code/beta',
            startedAt: 1,
          ),
        ),
      );
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
      // Rename stays on the pencil; deletion moved to a left-swipe on the
      // whole session row (no more long-press menu).
      expect(find.byTooltip('Rename session'), findsOneWidget);
      final betaDelete = find.byKey(
        ValueKey('session-delete-${peer.remoteEpk}-beta'),
      );
      expect(betaDelete, findsOneWidget);
      final betaRow = find.byKey(
        ValueKey('session-row-${peer.remoteEpk}-beta'),
      );
      await tester.ensureVisible(betaRow);
      await tester.pumpAndSettle();
      final betaCenter = tester.getCenter(betaRow);
      await tester.dragFrom(
        Offset(betaCenter.dx + 70, betaCenter.dy),
        const Offset(-260, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete from phone?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Rename session'));
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

      final renamedBeta = find.byKey(
        ValueKey('session-row-${peer.remoteEpk}-beta'),
      );
      await tester.ensureVisible(renamedBeta);
      await tester.pumpAndSettle();
      final renamedCenter = tester.getCenter(renamedBeta);
      await tester.dragFrom(
        Offset(renamedCenter.dx + 70, renamedCenter.dy),
        const Offset(-260, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete from phone?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Delete'),
        ),
      );
      await tester.pumpAndSettle();
      channel.control.add(
        RoomAnnounced(
          peer: peer.remoteEpk,
          room: RoomInfo(
            roomId: 'beta',
            name: 'Beta task',
            cwd: '/code/beta',
            startedAt: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(vm.allItems.map((item) => item.room.roomId), ['alpha']);
      final restored = Preferences();
      await restored.load();
      expect(restored.isSessionHidden(peer.remoteEpk, 'beta'), isTrue);
      restored.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await cleanup();
      await tester.pump();
    },
  );
}
