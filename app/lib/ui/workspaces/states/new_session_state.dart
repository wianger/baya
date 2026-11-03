import 'package:app/domain/workspaces/workspace_repository.dart';

/// Immutable workspace snapshot captured from the sidebar before the route is
/// pushed. The new-session route owns its selection so browsing another
/// computer cannot change the visible workspace list underneath it.
class NewSessionLaunch {
  const NewSessionLaunch({this.workspaces = const [], this.selectedWorkspace});

  final List<WorkspaceGroup> workspaces;
  final String? selectedWorkspace;
}

sealed class NewSessionState {
  const NewSessionState();
}

class NewSessionLoading extends NewSessionState {
  const NewSessionLoading();
}

class NewSessionUnavailable extends NewSessionState {
  const NewSessionUnavailable(this.message);
  final String message;
}

class NewSessionReady extends NewSessionState {
  const NewSessionReady({
    required this.hosts,
    required this.host,
    this.workspaces = const [],
    this.selectedWorkspace,
    this.directory,
    this.agent = const WorkspaceAgent(id: '', label: ''),
    this.loading = false,
    this.opening = false,
    this.showHidden = false,
    this.query = '',
    this.error,
  });
  final List<WorkspaceHost> hosts;
  final WorkspaceHost host;
  final List<WorkspaceGroup> workspaces;
  final String? selectedWorkspace;
  final WorkspaceDirectory? directory;
  final WorkspaceAgent agent;
  final bool loading;
  final bool opening;
  final bool showHidden;
  final String query;
  final String? error;

  bool get canOpen =>
      host.online &&
      selectedWorkspace != null &&
      !loading &&
      !opening &&
      directory?.availableAgents.contains(agent) == true;
  List<WorkspaceGroup> get workspacesForHost => workspaces
      .where((workspace) => workspace.deviceId == host.id)
      .toList(growable: false);
  WorkspaceGroup? get selectedWorkspaceGroup {
    final key = selectedWorkspace;
    if (key == null) return null;
    return workspaces
        .where((workspace) => workspace.workspaceKey == key)
        .firstOrNull;
  }

  List<WorkspaceFolder> get visibleFolders =>
      directory?.folders
          .where(
            (folder) =>
                folder.name.toLowerCase().contains(query.trim().toLowerCase()),
          )
          .toList() ??
      const [];

  NewSessionReady copyWith({
    List<WorkspaceHost>? hosts,
    WorkspaceHost? host,
    List<WorkspaceGroup>? workspaces,
    String? selectedWorkspace,
    WorkspaceDirectory? directory,
    WorkspaceAgent? agent,
    bool? loading,
    bool? opening,
    bool? showHidden,
    String? query,
    String? error,
    bool clearDirectory = false,
    bool clearSelectedWorkspace = false,
    bool clearError = false,
  }) => NewSessionReady(
    hosts: hosts ?? this.hosts,
    host: host ?? this.host,
    workspaces: workspaces ?? this.workspaces,
    selectedWorkspace: clearSelectedWorkspace
        ? null
        : selectedWorkspace ?? this.selectedWorkspace,
    directory: clearDirectory ? null : directory ?? this.directory,
    agent: agent ?? this.agent,
    loading: loading ?? this.loading,
    opening: opening ?? this.opening,
    showHidden: showHidden ?? this.showHidden,
    query: query ?? this.query,
    error: clearError ? null : error ?? this.error,
  );

  @override
  bool operator ==(Object other) =>
      other is NewSessionReady &&
      identical(hosts, other.hosts) &&
      host.id == other.host.id &&
      identical(workspaces, other.workspaces) &&
      selectedWorkspace == other.selectedWorkspace &&
      identical(directory, other.directory) &&
      agent == other.agent &&
      loading == other.loading &&
      opening == other.opening &&
      showHidden == other.showHidden &&
      query == other.query &&
      error == other.error;
  @override
  int get hashCode => Object.hash(
    hosts,
    host.id,
    workspaces,
    selectedWorkspace,
    directory,
    agent,
    loading,
    opening,
    showHidden,
    query,
    error,
  );
}
