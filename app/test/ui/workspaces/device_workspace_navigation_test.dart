import 'dart:convert';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/workspace_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../support/acp_harness.dart';

void main() {
  testWidgets(
    'sidebar scrolls its header instead of overflowing in short windows',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final pc = testPeer();
      final prefs = Preferences();
      await prefs.load();
      await prefs.setSelectedWorkspace(inboxWorkspaceKey(pc.remoteEpk));
      final storage = MemoryStorage([pc]);
      final host = FakeHost(
        sessions: [
          testSession(
            id: 'pc-one',
            cwd: '/code/shared',
            title: 'Desktop one',
            updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
          ),
          testSession(
            id: 'pc-two',
            cwd: '/code/shared',
            title: 'Desktop two',
            updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
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
            ChangeNotifierProvider.value(value: selection),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 330,
                  height: 480,
                  child: SessionSidebar(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The fixed header stack is taller than 480dp; it must scroll with the
      // session list instead of throwing a RenderFlex overflow.
      expect(tester.takeException(), isNull);
      final sidebarList = find.byType(ListView).first;
      expect(tester.getRect(sidebarList).bottom, greaterThan(360));
      await tester.dragUntilVisible(
        find.text('Desktop one'),
        sidebarList,
        const Offset(0, -80),
      );
      expect(find.text('Desktop one'), findsOneWidget);
      // Bottom actions stay pinned and tappable below the scroll area.
      // Pairing moved into the device sheet, so the sidebar keeps a single
      // settings action.
      expect(find.byKey(const Key('sidebar-pair')), findsNothing);
      expect(find.byKey(const Key('sidebar-settings')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
      hosts.dispose();
      prefs.dispose();
      selection.dispose();
    },
  );

  testWidgets(
    'device then workspace scopes sessions and remembers each device across relaunch',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final pc = testPeer();
      final laptop = testPeer(seed: 7, name: 'Laptop');
      final empty = testPeer(seed: 8, name: 'Empty device');
      final prefs = Preferences();
      await prefs.load();
      final notesWorkspace = workspaceKey(pc.remoteEpk, 'notes');
      await prefs.setWorkspaceName(notesWorkspace, 'notes');
      await prefs.setSessionWorkspace(pc.remoteEpk, 'pc-notes', notesWorkspace);
      await prefs.setSelectedWorkspace(inboxWorkspaceKey(pc.remoteEpk));
      final storage = MemoryStorage([pc, laptop, empty]);
      final hosts = testHostsFor(storage, {
        pc.remoteEpk: FakeHost(
          sessions: [
            testSession(
              id: 'pc-one',
              title: 'Desktop one',
              cwd: '/code/shared',
            ),
            testSession(
              id: 'pc-two',
              title: 'Desktop two',
              cwd: '/code/shared',
            ),
            testSession(
              id: 'pc-notes',
              title: 'Desktop notes',
              cwd: '/code/notes',
            ),
          ],
        ),
        laptop.remoteEpk: FakeHost(
          sessions: [
            testSession(
              id: 'laptop-one',
              title: 'Laptop task',
              cwd: '/code/shared',
            ),
          ],
        ),
        empty.remoteEpk: FakeHost(),
      });
      await hosts.start();
      final vm = HomeViewModel(hosts, storage, prefs);
      final selection = SessionSelection();
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
      expect(
        vm.workspaceGroups.where(
          (workspace) => workspace.deviceId == laptop.remoteEpk,
        ),
        isNotEmpty,
      );
      expect(find.text('Desktop one'), findsOneWidget);
      expect(find.text('Desktop two'), findsOneWidget);
      expect(find.text('Laptop task'), findsNothing);
      Future<void> choose(String key, String value) async {
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        await tester.tap(find.text(value).last);
        await tester.pumpAndSettle();
      }

      await choose('workspace-selector', 'notes');
      expect(find.text('Desktop notes'), findsOneWidget);
      await choose('device-switch', 'Laptop');
      expect(find.text('Laptop task'), findsOneWidget);
      expect(find.text('Desktop notes'), findsNothing);
      expect(vm.workspaces.length, 1);
      expect(vm.workspaces.keys.single, inboxWorkspaceKey(laptop.remoteEpk));
      await choose('device-switch', 'Empty device');
      expect(vm.workspaceItems, isEmpty);
      expect(vm.workspaces.keys.single, inboxWorkspaceKey(empty.remoteEpk));
      expect(find.text('Inbox'), findsOneWidget);
      await choose('device-switch', 'PC');
      expect(find.text('Desktop notes'), findsOneWidget);
      expect(find.text('Desktop one'), findsNothing);
      final restored = Preferences();
      await restored.load();
      expect(restored.selectedDeviceEpk, pc.remoteEpk);
      expect(restored.workspaceForDevice(pc.remoteEpk), notesWorkspace);
      restored.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await cleanup();
      await tester.pump();
    },
  );

  test('a logical workspace groups sessions from unrelated folders', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final pc = testPeer();
    final prefs = Preferences();
    await prefs.load();
    final storage = MemoryStorage([pc]);
    final host = FakeHost();
    final hosts = testHosts(storage, host);
    await hosts.start();
    await settle();
    final vm = HomeViewModel(hosts, storage, prefs);
    host.push('_baya/session_changed', {
      'session': testSession(
        id: 'session-alpha',
        cwd: '/code/api',
        title: 'API',
        updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      ).toJson(),
    });
    host.push('_baya/session_changed', {
      'session': testSession(
        id: 'session-beta',
        cwd: '/code/mobile',
        title: 'Mobile',
        updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      ).toJson(),
    });
    await pumpEventQueue();
    final alpha = vm.allItems.firstWhere(
      (item) => item.sessionId == 'session-alpha',
    );
    final beta = vm.allItems.firstWhere(
      (item) => item.sessionId == 'session-beta',
    );

    final workspace = await vm.createWorkspace(
      name: 'Release train',
      deviceEpk: pc.remoteEpk,
    );
    await vm.assignSessionIdToWorkspace(
      alpha.peer.remoteEpk,
      alpha.sessionId,
      workspace,
    );
    await vm.assignSessionIdToWorkspace(
      beta.peer.remoteEpk,
      beta.sessionId,
      workspace,
    );
    await pumpEventQueue();

    expect(vm.selectedWorkspace, workspace);
    expect(
      vm.workspaceItems.map((item) => item.sessionId),
      unorderedEquals(['session-alpha', 'session-beta']),
    );
    expect(vm.workspaces[workspace], '2 sessions · 2 folders');

    await vm.openSession(pc.remoteEpk, 'session-alpha');
    expect(
      vm.selectedWorkspace,
      workspace,
      reason: 'opening a grouped session must keep its logical workspace',
    );

    final restored = Preferences();
    await restored.load();
    expect(restored.workspaceName(workspace), 'Release train');
    expect(
      restored.workspaceForSession(pc.remoteEpk, 'session-alpha'),
      workspace,
    );
    expect(
      restored.workspaceForSession(pc.remoteEpk, 'session-beta'),
      workspace,
    );
    restored.dispose();

    await vm.deleteWorkspace(workspace);
    await pumpEventQueue();
    expect(vm.selectedWorkspace, inboxWorkspaceKey(pc.remoteEpk));
    expect(
      vm.workspaceItems.map((item) => item.sessionId),
      unorderedEquals(['session-alpha', 'session-beta']),
      reason: 'Deleting a workspace moves all of its sessions to Inbox',
    );

    final restoredAfterDelete = Preferences();
    await restoredAfterDelete.load();
    expect(restoredAfterDelete.workspaceName(workspace), isNull);
    expect(
      restoredAfterDelete.workspaceForSession(pc.remoteEpk, 'session-alpha'),
      isNull,
    );
    expect(
      restoredAfterDelete.workspaceForSession(pc.remoteEpk, 'session-beta'),
      isNull,
    );
    restoredAfterDelete.dispose();
    vm.dispose();
    hosts.dispose();
    prefs.dispose();
  });

  test(
    'sessions in one folder can belong to different logical workspaces',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final pc = testPeer();
      final prefs = Preferences();
      await prefs.load();
      final storage = MemoryStorage([pc]);
      final host = FakeHost();
      final hosts = testHosts(storage, host);
      await hosts.start();
      await settle();
      final vm = HomeViewModel(hosts, storage, prefs);
      host.push('_baya/session_changed', {
        'session': testSession(
          id: 'session-alpha',
          cwd: '/code/project',
          title: 'Alpha',
          updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        ).toJson(),
      });
      host.push('_baya/session_changed', {
        'session': testSession(
          id: 'session-beta',
          cwd: '/code/project',
          title: 'Beta',
          updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        ).toJson(),
      });
      await pumpEventQueue();

      final alphaWorkspace = await vm.createWorkspace(
        name: 'Alpha workspace',
        deviceEpk: pc.remoteEpk,
      );
      final betaWorkspace = await vm.createWorkspace(
        name: 'Beta workspace',
        deviceEpk: pc.remoteEpk,
      );
      await vm.assignSessionIdToWorkspace(
        pc.remoteEpk,
        'session-alpha',
        alphaWorkspace,
      );
      await vm.assignSessionIdToWorkspace(
        pc.remoteEpk,
        'session-beta',
        betaWorkspace,
      );
      await pumpEventQueue();

      await vm.selectWorkspace(alphaWorkspace);
      expect(vm.workspaceItems.map((item) => item.sessionId), [
        'session-alpha',
      ]);

      await vm.selectWorkspace(betaWorkspace);
      expect(vm.workspaceItems.map((item) => item.sessionId), ['session-beta']);

      await vm.selectWorkspace(inboxWorkspaceKey(pc.remoteEpk));
      expect(vm.workspaceItems, isEmpty);

      vm.dispose();
      hosts.dispose();
      prefs.dispose();
    },
  );

  test('url-safe device ids share one canonical Inbox', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final rawEpk = base64UrlEncode(List.filled(32, 251));
    final canonicalEpk = base64Encode(List.filled(32, 251));
    expect(canonicalEpk, isNot(rawEpk));
    final pc = PeerRecord(
      remoteEpk: rawEpk,
      name: 'PC',
      endpoint: 'https://example.invalid',
      pairedAt: '2026-10-30',
    );
    final prefs = Preferences();
    await prefs.load();
    final storage = MemoryStorage([pc]);
    final host = FakeHost();
    final hosts = testHosts(storage, host);
    await hosts.start();
    await settle();
    final vm = HomeViewModel(hosts, storage, prefs);
    host.push('_baya/session_changed', {
      'session': testSession(
        id: 'session-alpha',
        cwd: '/code/project',
        title: 'Alpha',
        updatedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      ).toJson(),
    });
    await pumpEventQueue();

    final inbox = inboxWorkspaceKey(canonicalEpk);
    expect(vm.workspaces, hasLength(1));
    expect(vm.workspaces.keys.single, inbox);
    expect(vm.workspaceItems.map((item) => item.sessionId), ['session-alpha']);

    vm.dispose();
    hosts.dispose();
    prefs.dispose();
  });

  test(
    'drops folder workspace selections and serializes logical selections',
    () async {
      final pc = testPeer().remoteEpk;
      final laptop = base64Encode(List.filled(32, 7));
      const old = '/code/old';
      final laptopWorkspace = workspaceKey(laptop, 'laptop-work');
      FlutterSecureStorage.setMockInitialValues({
        'prefs.selected_workspace': old,
        'prefs.workspace_navigation':
            '{"device":"$pc","workspaces":{"$pc":"$pc:/code/old"}}',
      });
      final prefs = Preferences();
      await prefs.load();
      expect(prefs.workspaceForDevice(pc), isNull);
      await Future.wait([
        prefs.setSelectedWorkspace(laptopWorkspace),
        prefs.setSelectedDevice(pc),
      ]);
      final restored = Preferences();
      await restored.load();
      expect(restored.selectedDeviceEpk, pc);
      expect(restored.workspaceForDevice(laptop), laptopWorkspace);
      expect(restored.selectedWorkspace, isNull);
      prefs.dispose();
      restored.dispose();
    },
  );

  testWidgets(
    'new session assigns its result to the workspace returned by the picker',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final pc = testPeer();
      final prefs = Preferences();
      await prefs.load();
      final storage = MemoryStorage([pc]);
      final host = FakeHost(sessions: []);
      final hosts = testHosts(storage, host);
      await hosts.start();
      final vm = HomeViewModel(hosts, storage, prefs);
      final selection = SessionSelection();

      final first = await vm.createWorkspace(
        name: 'First workspace',
        deviceEpk: pc.remoteEpk,
      );
      final second = await vm.createWorkspace(
        name: 'Second workspace',
        deviceEpk: pc.remoteEpk,
      );

      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, _) => ChangeNotifierProvider.value(
              value: vm,
              child: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => openNewSession(context),
                    child: const Text('Open new session'),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/new-session',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).pop(
                  OpenedWorkspace(
                    hostId: pc.remoteEpk,
                    hostLabel: 'PC',
                    path: '/project',
                    sessionId: 'created-room',
                    name: 'project',
                    agent: const WorkspaceAgent(
                      id: 'claude',
                      label: 'Claude Code',
                    ),
                    workspaceKey: first,
                  ),
                ),
                child: const Text('Finish new session'),
              ),
            ),
          ),
          GoRoute(
            path: '/chat',
            builder: (context, _) => const Scaffold(body: Text('Chat')),
          ),
        ],
      );
      var cleaned = false;
      Future<void> cleanup() async {
        if (cleaned) return;
        cleaned = true;
        router.dispose();
        vm.dispose();
        hosts.dispose();
        prefs.dispose();
        selection.dispose();
      }

      addTearDown(cleanup);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: selection,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await vm.selectWorkspace(second);
      await tester.tap(find.text('Open new session'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Finish new session'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.text('Chat'), findsOneWidget);
      expect(prefs.workspaceForSession(pc.remoteEpk, 'created-room'), first);
      expect(prefs.selectedDeviceEpk, pc.remoteEpk);
      expect(prefs.workspaceForDevice(pc.remoteEpk), first);
      expect(selection.current?.sessionId, 'created-room');
      await tester.pumpWidget(const SizedBox.shrink());
      await cleanup();
      await tester.pump();
    },
  );
}
