import 'package:app/domain/workspaces/workspace_repository.dart';

/// Keep future ids and availability metadata from a paired computer intact.
List<WorkspaceAgent> decodeWorkspaceAgents(Object? raw) {
  if (raw is! List) return const [];
  final agents = <String, WorkspaceAgent>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = entry['id'];
    if (id is! String || id.trim().isEmpty || agents.containsKey(id)) continue;
    final name = entry['name'];
    agents[id] = WorkspaceAgent(
      id: id,
      label: name is String && name.trim().isNotEmpty ? name : id,
      description: switch (entry['description']) {
        final String text => text,
        _ => '',
      },
      available: entry['available'] == true,
      unavailableReason: switch (entry['reason']) {
        final String text => text,
        _ => null,
      },
    );
  }
  return List.unmodifiable(agents.values);
}
