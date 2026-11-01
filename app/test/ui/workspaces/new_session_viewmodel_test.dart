import 'dart:async';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/workspaces/states/new_session_state.dart';
import 'package:app/ui/workspaces/viewmodels/new_session_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

const host = WorkspaceHost(id: 'computer', label: 'Computer', online: true);
const secondHost = WorkspaceHost(
  id: 'second-computer',
  label: 'Second computer',
  online: true,
);
const defaultLaunch = NewSessionLaunch(
  workspaces: [
    WorkspaceGroup(
      workspaceKey: 'computer:workspace:default',
      deviceId: 'computer',
      label: 'Default',
      subtitle: '1 session',
    ),
    WorkspaceGroup(
      workspaceKey: 'computer:workspace:secondary',
      deviceId: 'computer',
      label: 'Secondary',
      subtitle: 'No sessions yet',
    ),
    WorkspaceGroup(
      workspaceKey: 'second-computer:workspace:default',
      deviceId: 'second-computer',
      label: 'Second workspace',
      subtitle: '2 sessions',
    ),
  ],
  selectedWorkspace: 'computer:workspace:default',
);
WorkspaceDirectory directory(
  String path, {
  List<WorkspaceAgent> agents = const [WorkspaceAgent.pi, WorkspaceAgent.codex],
}) => WorkspaceDirectory(
  path: path,
  home: '/home',
  parent: '/',
  roots: const ['/'],
  folders: const [WorkspaceFolder(name: 'project', path: '/project')],
  agents: agents,
);

class FakeWorkspaces extends IWorkspaceRepository {
  FakeWorkspaces({List<WorkspaceHost>? hosts}) : hosts = hosts ?? const [host];
  final List<WorkspaceHost> hosts;
  @override
  WorkspaceSelection? get currentSelection =>
      const WorkspaceSelection('computer', 'original');
  @override
  Future<List<WorkspaceHost>> listHosts() async => hosts;
  Future<WorkspaceDirectory> Function(String)? onBrowse;
  Future<WorkspaceDirectory> Function(String, String)? onBrowseHost;
  final requestedHosts = <String>[];
  final opened = <WorkspaceAgent>[];
  final restored = <WorkspaceSelection?>[];
  @override
  Future<WorkspaceDirectory> browse(
    String hostId, {
    String? path,
    bool showHidden = false,
  }) async {
    requestedHosts.add(hostId);
    final resolvedPath = path ?? '/home';
    if (onBrowseHost != null) {
      return onBrowseHost!(hostId, resolvedPath);
    }
    return onBrowse == null
        ? directory(resolvedPath)
        : await onBrowse!(resolvedPath);
  }

  @override
  Future<OpenedWorkspace> open(
    String hostId,
    String path,
    WorkspaceAgent agent,
  ) async {
    opened.add(agent);
    return OpenedWorkspace(
      hostId: hostId,
      hostLabel: host.label,
      path: path,
      roomId: 'new',
      name: 'project',
      agent: agent,
    );
  }

  @override
  Future<void> restore(WorkspaceSelection? selection) async {
    restored.add(selection);
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('a workspace is required before opening a session', () async {
    final repo = FakeWorkspaces();
    final vm = NewSessionViewModel(repo);
    await tick();

    final state = vm.state as NewSessionReady;
    expect(state.workspacesForHost, isEmpty);
    expect(state.selectedWorkspace, isNull);
    expect(state.canOpen, isFalse);
    expect(await vm.open(), isNull);
    expect(repo.opened, isEmpty);
    vm.dispose();
  });

  test(
    'future agent ids are selected and opened without a mobile whitelist',
    () async {
      const future = WorkspaceAgent(id: 'future-agent', label: 'New Agent');
      const unavailable = WorkspaceAgent(
        id: 'offline-agent',
        label: 'Unavailable',
        available: false,
      );
      final repo = FakeWorkspaces()
        ..onBrowse = (path) async =>
            directory(path, agents: [future, unavailable]);
      final vm = NewSessionViewModel(repo, launch: defaultLaunch);
      await tick();
      expect((vm.state as NewSessionReady).agent.id, 'future-agent');
      vm.setAgent(
        const WorkspaceAgent(
          id: 'offline-agent',
          label: 'Spoofed availability',
        ),
      );
      expect((vm.state as NewSessionReady).agent.id, 'future-agent');
      final opened = await vm.open();
      expect(opened!.agent.id, 'future-agent');
      expect(repo.opened.single.id, 'future-agent');
      vm.dispose();
    },
  );

  test(
    'catalog refresh keeps the selected id and refreshes its label',
    () async {
      final repo = FakeWorkspaces();
      final vm = NewSessionViewModel(repo, launch: defaultLaunch);
      await tick();
      vm.setAgent(WorkspaceAgent.codex);
      repo.onBrowse = (path) async => directory(
        path,
        agents: const [WorkspaceAgent(id: 'codex', label: 'Computer Codex')],
      );
      await vm.browse(path: '/project');
      expect((vm.state as NewSessionReady).agent.label, 'Computer Codex');
      vm.dispose();
    },
  );

  test('switching computers refreshes folders and clears loading', () async {
    final repo = FakeWorkspaces(hosts: const [host, secondHost])
      ..onBrowseHost = (hostId, _) async => directory('/$hostId');
    final vm = NewSessionViewModel(repo, launch: defaultLaunch);
    await tick();
    await tick();
    vm.setWorkspace('computer:workspace:secondary');
    expect(
      (vm.state as NewSessionReady).selectedWorkspace,
      'computer:workspace:secondary',
    );

    await vm.selectHost(secondHost.id);
    final state = vm.state as NewSessionReady;
    expect(state.host.id, secondHost.id);
    expect(state.selectedWorkspace, 'second-computer:workspace:default');
    expect(state.directory!.path, '/${secondHost.id}');
    expect(state.loading, isFalse);
    expect(state.error, isNull);
    expect(repo.requestedHosts.last, secondHost.id);

    await vm.selectHost(host.id);
    expect(
      (vm.state as NewSessionReady).selectedWorkspace,
      'computer:workspace:secondary',
    );
    vm.dispose();
  });

  test(
    'a stalled folder request exits loading with a retryable error',
    () async {
      final repo = FakeWorkspaces();
      final stalled = Completer<WorkspaceDirectory>();
      repo.onBrowse = (_) => stalled.future;
      final vm = NewSessionViewModel(
        repo,
        launch: defaultLaunch,
        browseTimeout: const Duration(milliseconds: 20),
      );
      await tick();
      expect((vm.state as NewSessionReady).loading, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 35));
      final state = vm.state as NewSessionReady;
      expect(state.loading, isFalse);
      expect(state.error, contains('did not connect in time'));
      vm.dispose();
    },
  );

  test('a failed computer switch can retry the selected device', () async {
    final repo = FakeWorkspaces(hosts: const [host, secondHost])
      ..onBrowseHost = (hostId, _) async {
        if (hostId == secondHost.id) {
          throw const WorkspaceFailure('The computer is offline.');
        }
        return directory('/$hostId');
      };
    final vm = NewSessionViewModel(repo, launch: defaultLaunch);
    await tick();
    await tick();

    await vm.selectHost(secondHost.id);
    var state = vm.state as NewSessionReady;
    expect(state.host.id, secondHost.id);
    expect(state.directory, isNull);
    expect(state.loading, isFalse);
    expect(state.error, 'The computer is offline.');

    repo.onBrowseHost = (hostId, _) async => directory('/$hostId');
    await vm.retryBrowse();
    state = vm.state as NewSessionReady;
    expect(state.host.id, secondHost.id);
    expect(state.directory!.path, '/${secondHost.id}');
    expect(state.loading, isFalse);
    expect(state.error, isNull);
    vm.dispose();
  });

  test(
    'loads folders, selects Codex and opens the chosen computer directory',
    () async {
      final repo = FakeWorkspaces();
      final vm = NewSessionViewModel(repo, launch: defaultLaunch);
      await tick();
      expect((vm.state as NewSessionReady).directory!.path, '/home');
      await vm.browse(path: '/project');
      vm.setAgent(WorkspaceAgent.codex);
      final result = await vm.open();
      expect(result!.path, '/project');
      expect(result.workspaceKey, 'computer:workspace:default');
      expect(repo.opened, [WorkspaceAgent.codex]);
      await vm.cancel();
      expect(repo.restored, isEmpty);
      vm.dispose();
    },
  );

  test('late folder response cannot overwrite a newer navigation', () async {
    final repo = FakeWorkspaces();
    final vm = NewSessionViewModel(repo, launch: defaultLaunch);
    await tick();
    final old = Completer<WorkspaceDirectory>();
    repo.onBrowse = (path) =>
        path == '/old' ? old.future : Future.value(directory(path));
    final pending = vm.browse(path: '/old');
    await vm.browse(path: '/new');
    old.complete(directory('/old'));
    await pending;
    expect((vm.state as NewSessionReady).directory!.path, '/new');
    vm.dispose();
  });

  test(
    'cancel invalidates folder response and restores the previous room once',
    () async {
      final repo = FakeWorkspaces();
      final vm = NewSessionViewModel(repo, launch: defaultLaunch);
      await tick();
      final response = Completer<WorkspaceDirectory>();
      repo.onBrowse = (_) => response.future;
      final browse = vm.browse(path: '/pending');
      await vm.cancel();
      await vm.cancel();
      response.complete(directory('/pending'));
      await browse;
      expect(repo.restored.single!.roomId, 'original');
      expect((vm.state as NewSessionReady).directory!.path, '/home');
      vm.dispose();
    },
  );

  test('shows startup error and allows retry', () async {
    final repo = FakeWorkspaces();
    final vm = NewSessionViewModel(repo, launch: defaultLaunch);
    await tick();
    repo.onBrowse = (_) async => throw const WorkspaceFailure('offline');
    await vm.browse(path: '/new');
    expect((vm.state as NewSessionReady).error, 'offline');
    expect((vm.state as NewSessionReady).loading, false);
    vm.dispose();
  });
}
