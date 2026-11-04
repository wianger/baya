import 'package:app/acp/acp.dart';
import 'package:app/domain/runs/parallel_run.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

import '../states/new_session_state.dart';

class NewSessionViewModel extends ViewModel<NewSessionState> {
  NewSessionViewModel(
    this._repository, {
    NewSessionLaunch launch = const NewSessionLaunch(),
    // A device switch can spend up to 10 seconds opening the replacement
    // connection (plus a bounded teardown) before the folder request starts.
    // Keep the page-level deadline beyond the repository request deadline so
    // the UI does not reject a switch while its real request is still alive.
    this.browseTimeout = const Duration(seconds: 40),
  }) : super(const NewSessionLoading()) {
    _workspaces = launch.workspaces;
    if (launch.selectedWorkspace case final selected?) {
      final workspace = _workspaces
          .where((entry) => entry.workspaceKey == selected)
          .firstOrNull;
      if (workspace != null) {
        _rememberedWorkspaceByDevice[workspace.deviceId] = selected;
      }
    }
    load();
  }
  final IWorkspaceRepository _repository;
  final Duration browseTimeout;
  late final List<WorkspaceGroup> _workspaces;
  final _rememberedWorkspaceByDevice = <String, String>{};
  bool _disposed = false;
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    emit(const NewSessionLoading());
    try {
      final hosts = await _repository.listHosts();
      if (_disposed || generation != _generation) return;
      if (hosts.isEmpty) {
        emit(NewSessionUnavailable(appL10n.pairToOpenSession));
        return;
      }
      final available = hosts.where((host) => host.online).toList();
      final host = available.isNotEmpty ? available.first : hosts.first;
      final workspace = _workspaceForHost(host.id);
      emit(
        NewSessionReady(
          hosts: hosts,
          host: host,
          workspaces: _workspaces,
          selectedWorkspace: workspace?.workspaceKey,
        ),
      );
      await browse();
    } catch (error) {
      if (!_disposed && generation == _generation) {
        emit(
          NewSessionUnavailable(
            error is WorkspaceFailure
                ? error.message
                : appL10n.couldNotLoadComputers,
          ),
        );
      }
    }
  }

  Future<void> selectHost(String hostId) async {
    final current = state;
    if (current is! NewSessionReady ||
        current.opening ||
        current.host.id == hostId) {
      return;
    }
    final matches = current.hosts.where((host) => host.id == hostId);
    if (matches.isEmpty) return;
    final nextHost = matches.first;
    if (current.selectedWorkspace case final selected?) {
      _rememberedWorkspaceByDevice[current.host.id] = selected;
    }
    final workspace = _workspaceForHost(nextHost.id);
    emit(
      current.copyWith(
        host: nextHost,
        selectedWorkspace: workspace?.workspaceKey,
        clearSelectedWorkspace: workspace == null,
        clearDirectory: true,
        clearError: true,
        loading: true,
        query: '',
      ),
    );
    await browse();
  }

  Future<void> retryBrowse() async {
    final current = state;
    if (current is! NewSessionReady || current.opening) return;
    await browse(path: current.directory?.path);
  }

  Future<void> browse({String? path}) async {
    final current = state;
    if (current is! NewSessionReady || current.opening) return;
    final generation = ++_generation;
    emit(current.copyWith(loading: true, clearError: true, query: ''));
    try {
      final directory = await _repository
          .browse(current.host.id, path: path, showHidden: current.showHidden)
          .timeout(
            browseTimeout,
            onTimeout: () {
              throw WorkspaceFailure(appL10n.computerDidNotConnect);
            },
          );
      if (_disposed || generation != _generation) return;
      final available = directory.availableAgents;
      final selected = available.where((agent) => agent.id == current.agent.id);
      final agent = selected.isNotEmpty
          ? selected.first
          : available.isNotEmpty
          ? available.first
          : directory.agents.isNotEmpty
          ? directory.agents.first
          : current.agent;
      final latest = state;
      if (latest is NewSessionReady) {
        emit(
          latest.copyWith(
            directory: directory,
            agent: agent,
            loading: false,
            clearError: true,
          ),
        );
      }
    } catch (error) {
      if (_disposed || generation != _generation) return;
      final latest = state;
      if (latest is NewSessionReady) {
        emit(
          latest.copyWith(
            loading: false,
            error: error is WorkspaceFailure
                ? error.message
                : appL10n.couldNotReadFolder,
          ),
        );
      }
    }
  }

  void setAgent(WorkspaceAgent agent) {
    final current = state;
    if (current is! NewSessionReady ||
        current.opening ||
        current.agent == agent ||
        current.directory?.availableAgents.contains(agent) != true) {
      return;
    }
    final choice = current.directory!.availableAgents.firstWhere(
      (entry) => entry.id == agent.id,
    );
    emit(
      current.copyWith(
        agent: choice,
        alsoAgents: current.alsoAgents
            .where((other) => other.id != choice.id)
            .toList(growable: false),
      ),
    );
  }

  /// Adds [agent] to, or takes it out of, the agents that run alongside.
  void toggleAlsoAgent(WorkspaceAgent agent) {
    final current = state;
    if (current is! NewSessionReady ||
        current.opening ||
        agent.id == current.agent.id ||
        current.directory?.availableAgents.any((a) => a.id == agent.id) !=
            true) {
      return;
    }
    final present = current.alsoAgents.any((other) => other.id == agent.id);
    emit(
      current.copyWith(
        alsoAgents: present
            ? current.alsoAgents
                  .where((other) => other.id != agent.id)
                  .toList(growable: false)
            : [...current.alsoAgents, agent],
      ),
    );
  }

  void setSeparateWorktrees(bool value) {
    final current = state;
    if (current is NewSessionReady && !current.opening) {
      emit(current.copyWith(separateWorktrees: value));
    }
  }

  void setWorkspace(String workspaceKey) {
    final current = state;
    if (current is! NewSessionReady || current.opening) return;
    final workspace = current.workspacesForHost
        .where((entry) => entry.workspaceKey == workspaceKey)
        .firstOrNull;
    if (workspace == null || current.selectedWorkspace == workspaceKey) return;
    _rememberedWorkspaceByDevice[current.host.id] = workspaceKey;
    emit(current.copyWith(selectedWorkspace: workspaceKey));
  }

  void setQuery(String query) {
    final current = state;
    if (current is NewSessionReady && current.query != query) {
      emit(current.copyWith(query: query));
    }
  }

  Future<void> toggleHidden() async {
    final current = state;
    if (current is! NewSessionReady || current.opening) return;
    emit(current.copyWith(showHidden: !current.showHidden));
    await browse(path: current.directory?.path);
  }

  /// The agent's own conversations in this folder that Baya can continue.
  Future<List<AgentSessionInfo>> earlierSessions() async {
    final current = state;
    if (current is! NewSessionReady || !current.canOpen) return const [];
    return _repository.agentSessions(
      current.host.id,
      current.directory!.path,
      current.agent,
    );
  }

  /// Starts a session here, or continues [agentSessionId] from
  /// [earlierSessions].
  Future<OpenedWorkspace?> open({String? agentSessionId}) async {
    final current = state;
    if (current is! NewSessionReady || !current.canOpen) return null;
    emit(current.copyWith(opening: true, clearError: true));
    try {
      final result = await _repository.open(
        current.host.id,
        current.directory!.path,
        current.agent,
        agentSessionId: agentSessionId,
      );
      return _disposed
          ? null
          : result.withWorkspace(current.selectedWorkspace!);
    } catch (error) {
      if (!_disposed) {
        emit(
          current.copyWith(
            opening: false,
            error: error is WorkspaceFailure
                ? error.message
                : appL10n.couldNotStartSession,
          ),
        );
      }
      return null;
    }
  }

  /// Starts every agent of [NewSessionReady.runAgents] on the same folder,
  /// each in its own worktree when asked (and the folder is in a git
  /// repository). Agents that fail to start are left out; the run fails
  /// only when none starts.
  Future<ParallelRun?> openRun({DateTime? now}) async {
    final current = state;
    if (current is! NewSessionReady ||
        !current.canOpen ||
        current.alsoAgents.isEmpty) {
      return null;
    }
    emit(current.copyWith(opening: true, clearError: true));
    final folder = current.directory!.path;
    final hostId = current.host.id;
    final failures = <String>[];
    Future<RunMember?> start(WorkspaceAgent agent) async {
      try {
        final worktree = current.separateWorktrees
            ? await _repository.createWorktree(hostId, folder, agent.label)
            : null;
        final opened = await _repository.open(
          hostId,
          worktree?.path ?? folder,
          agent,
        );
        return RunMember(
          sessionId: opened.sessionId,
          agentId: agent.id,
          agentLabel: agent.label,
          path: opened.path,
          branch: worktree?.branch,
        );
      } catch (error) {
        failures.add('${agent.label}: $error');
        return null;
      }
    }

    final members = (await Future.wait(current.runAgents.map(start))).nonNulls
        .toList(growable: false);
    if (_disposed) return null;
    if (members.isEmpty) {
      emit(
        current.copyWith(
          opening: false,
          error: failures.isEmpty
              ? appL10n.couldNotStartSession
              : failures.join('\n'),
        ),
      );
      return null;
    }
    final started = now ?? DateTime.now();
    return ParallelRun(
      id: '${started.microsecondsSinceEpoch}',
      hostId: hostId,
      hostLabel: current.host.label,
      folder: folder,
      createdAt: started,
      members: members,
      workspaceKey: current.selectedWorkspace,
      failures: failures,
    );
  }

  /// Nothing to undo: browsing does not change any connection.
  Future<void> cancel() async {
    ++_generation;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }

  WorkspaceGroup? _workspaceForHost(String hostId) {
    final choices = _workspaces
        .where((workspace) => workspace.deviceId == hostId)
        .toList(growable: false);
    final remembered = _rememberedWorkspaceByDevice[hostId];
    if (remembered != null) {
      final match = choices
          .where((workspace) => workspace.workspaceKey == remembered)
          .firstOrNull;
      if (match != null) return match;
    }
    return choices.firstOrNull;
  }
}
