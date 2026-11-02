import 'package:app/domain/contracts/repository.dart';

/// Agent metadata supplied by the selected computer, identified by a stable id.
class WorkspaceAgent {
  const WorkspaceAgent({
    required this.id,
    required this.label,
    this.description = '',
    this.available = true,
    this.unavailableReason,
  });
  // The agents the host knows; the catalog it reports may differ.
  static const pi = WorkspaceAgent(
    id: 'pi',
    label: 'Pi',
    description: 'Pi coding agent',
  );
  static const codex = WorkspaceAgent(
    id: 'codex',
    label: 'Codex',
    description: 'Codex coding agent',
  );
  static const deepseek = WorkspaceAgent(
    id: 'deepseek',
    label: 'DeepSeek',
    description: 'DeepSeek Harness',
  );
  final String id;
  final String label;
  final String description;
  final bool available;
  final String? unavailableReason;

  @override
  bool operator ==(Object other) => other is WorkspaceAgent && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// Display label of an agent id (`codex` → `Codex`).
String workspaceAgentLabel(String? agent) => switch (agent) {
  null || '' => '',
  'pi' => WorkspaceAgent.pi.label,
  'codex' => WorkspaceAgent.codex.label,
  'deepseek' => WorkspaceAgent.deepseek.label,
  _ => agent[0].toUpperCase() + agent.substring(1),
};

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
    required this.roomId,
    required this.name,
    required this.agent,
    this.workspaceKey,
  });
  final String hostId;
  final String hostLabel;
  final String path;
  final String roomId;
  final String name;
  final WorkspaceAgent agent;
  final String? workspaceKey;

  OpenedWorkspace withWorkspace(String key) => OpenedWorkspace(
    hostId: hostId,
    hostLabel: hostLabel,
    path: path,
    roomId: roomId,
    name: name,
    agent: agent,
    workspaceKey: key,
  );
}

class WorkspaceSelection {
  const WorkspaceSelection(this.hostId, this.roomId);
  final String hostId;
  final String roomId;
}

class WorkspaceFailure implements Exception {
  const WorkspaceFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class IWorkspaceRepository extends Repository {
  WorkspaceSelection? get currentSelection;
  Future<List<WorkspaceHost>> listHosts();
  Future<WorkspaceDirectory> browse(
    String hostId, {
    String? path,
    bool showHidden = false,
  });
  Future<OpenedWorkspace> open(
    String hostId,
    String path,
    WorkspaceAgent agent,
  );
  Future<void> restore(WorkspaceSelection? selection);
}
