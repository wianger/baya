import 'package:app/domain/workspaces/workspace_repository.dart';
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
    _returnSelection = _repository.currentSelection;
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
  WorkspaceSelection? _returnSelection;
  bool _disposed = false;
  bool _restored = false;
  bool _opened = false;
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    emit(const NewSessionLoading());
    try {
      final hosts = await _repository.listHosts();
      if (_disposed || generation != _generation) return;
      if (hosts.isEmpty) {
        emit(const NewSessionUnavailable('Pair a computer to open a session.'));
        return;
      }
      final available = hosts.where((host) => host.online).toList();
      final selected = hosts
          .where((host) => host.id == _returnSelection?.hostId && host.online)
          .toList();
      final host = selected.isNotEmpty
          ? selected.first
          : available.isNotEmpty
          ? available.first
          : hosts.first;
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
                : 'Could not load your computers. Try again.',
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
              throw const WorkspaceFailure(
                'The selected computer did not connect in time. '
                'Start Baya on it, then try again.',
              );
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
                : 'Could not read this folder. Try again.',
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
    emit(current.copyWith(agent: choice));
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

  Future<OpenedWorkspace?> open() async {
    final current = state;
    if (current is! NewSessionReady || !current.canOpen) return null;
    emit(current.copyWith(opening: true, clearError: true));
    try {
      final result = await _repository.open(
        current.host.id,
        current.directory!.path,
        current.agent,
      );
      _opened = true;
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
                : 'Could not start the session. Try again.',
          ),
        );
      }
      return null;
    }
  }

  Future<void> cancel() async {
    if (_restored || _opened) return;
    _restored = true;
    ++_generation;
    try {
      await _repository.restore(_returnSelection);
    } catch (_) {
      /* A disconnected computer must not trap the user here. */
    }
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
