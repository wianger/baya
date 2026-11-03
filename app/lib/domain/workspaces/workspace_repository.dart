import 'package:app/acp/acp.dart';
import 'package:app/domain/contracts/repository.dart';

/// An agent set up on the selected computer (`baya agents`).
class WorkspaceAgent {
  const WorkspaceAgent({
    required this.id,
    required this.label,
    this.available = true,
  });
  final String id;
  final String label;
  final bool available;

  @override
  bool operator ==(Object other) => other is WorkspaceAgent && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class WorkspaceHost {
  const WorkspaceHost({
    required this.id,
    required this.label,
    required this.online,
  });
  final String id;
  final String label;
  final bool online;
}

class WorkspaceFolder {
  const WorkspaceFolder({required this.name, required this.path});
  final String name;
  final String path;
}

/// A logical workspace available while creating a session on one computer.
class WorkspaceGroup {
  const WorkspaceGroup({
    required this.workspaceKey,
    required this.deviceId,
    required this.label,
    required this.subtitle,
  });

  final String workspaceKey;
  final String deviceId;
  final String label;
  final String subtitle;
}

class WorkspaceDirectory {
  const WorkspaceDirectory({
    required this.path,
    required this.home,
    required this.parent,
    required this.roots,
    required this.folders,
    required this.agents,
    this.truncated = false,
  });
  final String path;
  final String home;
  final String? parent;
  final List<String> roots;
  final List<WorkspaceFolder> folders;

  /// The computer's agents (from `initialize`), for the agent picker.
  final List<WorkspaceAgent> agents;
  List<WorkspaceAgent> get availableAgents =>
      agents.where((agent) => agent.available).toList(growable: false);
  final bool truncated;
}

class OpenedWorkspace {
  const OpenedWorkspace({
    required this.hostId,
    required this.hostLabel,
    required this.path,
    required this.sessionId,
    required this.name,
    required this.agent,
    this.workspaceKey,
  });
  final String hostId;
  final String hostLabel;
  final String path;
  final String sessionId;
  final String name;
  final WorkspaceAgent agent;
  final String? workspaceKey;

  OpenedWorkspace withWorkspace(String key) => OpenedWorkspace(
    hostId: hostId,
    hostLabel: hostLabel,
    path: path,
    sessionId: sessionId,
    name: name,
    agent: agent,
    workspaceKey: key,
  );
}

class WorkspaceFailure implements Exception {
  const WorkspaceFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class IWorkspaceRepository extends Repository {
  Future<List<WorkspaceHost>> listHosts();

  /// The agent's own conversations in [path] that can be continued here.
  Future<List<AgentSessionInfo>> agentSessions(
    String hostId,
    String path,
    WorkspaceAgent agent,
  );
  Future<WorkspaceDirectory> browse(
    String hostId, {
    String? path,
    bool showHidden = false,
  });

  /// Starts a session, or continues the agent's own [agentSessionId].
  Future<OpenedWorkspace> open(
    String hostId,
    String path,
    WorkspaceAgent agent, {
    String? agentSessionId,
  });
}
