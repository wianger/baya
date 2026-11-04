/// Several agents given the same task side by side, each in its own
/// session (and, in a git repository, its own worktree and branch).
library;

class RunMember {
  const RunMember({
    required this.sessionId,
    required this.agentId,
    required this.agentLabel,
    required this.path,
    this.branch,
  });

  factory RunMember.fromJson(Map<String, dynamic> json) => RunMember(
    sessionId: json['sessionId'] as String,
    agentId: json['agentId'] as String? ?? '',
    agentLabel: json['agentLabel'] as String? ?? '',
    path: json['path'] as String? ?? '',
    branch: json['branch'] as String?,
  );

  final String sessionId;
  final String agentId;
  final String agentLabel;

  /// Where this agent works: the folder, or its worktree's copy of it.
  final String path;

  /// The worktree's branch; null when the agents share the folder.
  final String? branch;

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'agentId': agentId,
    'agentLabel': agentLabel,
    'path': path,
    'branch': ?branch,
  };
}

class ParallelRun {
  const ParallelRun({
    required this.id,
    required this.hostId,
    required this.hostLabel,
    required this.folder,
    required this.createdAt,
    required this.members,
    this.workspaceKey,
    this.failures = const [],
  });

  factory ParallelRun.fromJson(Map<String, dynamic> json) => ParallelRun(
    id: json['id'] as String,
    hostId: json['hostId'] as String,
    hostLabel: json['hostLabel'] as String? ?? '',
    folder: json['folder'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    members: [
      for (final member in (json['members'] as List? ?? const []))
        RunMember.fromJson((member as Map).cast<String, dynamic>()),
    ],
    workspaceKey: json['workspaceKey'] as String?,
  );

  final String id;
  final String hostId;
  final String hostLabel;

  /// The folder the run started from.
  final String folder;
  final DateTime createdAt;
  final List<RunMember> members;

  /// The phone's workspace the sessions were filed under.
  final String? workspaceKey;

  /// Agents that did not start, with why; shown once, not kept.
  final List<String> failures;

  /// The folder's name.
  String get name {
    final parts = folder.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? folder : parts.last;
  }

  bool get usesWorktrees => members.any((member) => member.branch != null);

  Map<String, dynamic> toJson() => {
    'id': id,
    'hostId': hostId,
    'hostLabel': hostLabel,
    'folder': folder,
    'createdAt': createdAt.toIso8601String(),
    'members': [for (final member in members) member.toJson()],
    'workspaceKey': ?workspaceKey,
  };
}
