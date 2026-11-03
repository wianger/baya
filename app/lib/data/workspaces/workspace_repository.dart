import 'package:app/acp/acp.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';

/// Folders and new sessions on a paired computer (`_baya/browse`,
/// `session/new`).
class WorkspaceRepository extends IWorkspaceRepository {
  WorkspaceRepository(this._hosts);

  final Hosts _hosts;

  @override
  Future<List<WorkspaceHost>> listHosts() async => [
    for (final host in _hosts.all)
      WorkspaceHost(
        id: host.key,
        label: host.host.label,
        online: host.isOnline,
      ),
  ];

  HostConnection _host(String hostId) {
    final host = _hosts.byKey(hostId);
    if (host == null) {
      throw const WorkspaceFailure(
        'Pair this computer before opening a session.',
      );
    }
    if (!host.isOnline) {
      throw WorkspaceFailure(
        '${host.host.label} is offline. Start Baya on the computer and try again.',
      );
    }
    return host;
  }

  @override
  Future<WorkspaceDirectory> browse(
    String hostId, {
    String? path,
    bool showHidden = false,
  }) async {
    final host = _host(hostId);
    final Map<String, dynamic> data;
    try {
      data = await host.call('_baya/browse', {
        'path': ?path,
        'showHidden': showHidden,
      });
    } catch (error) {
      throw WorkspaceFailure('$error');
    }
    return WorkspaceDirectory(
      path: data['path'] as String,
      home: data['home'] as String,
      parent: data['parent'] as String?,
      roots: (data['roots'] as List).cast<String>(),
      folders: [
        for (final entry
            in (data['directories'] as List).cast<Map<String, dynamic>>())
          WorkspaceFolder(
            name: entry['name'] as String,
            path: entry['path'] as String,
          ),
      ],
      agents: [
        for (final agent in host.agents)
          WorkspaceAgent(
            id: agent.id,
            label: agent.name,
            available: agent.available,
          ),
      ],
      truncated: data['truncated'] == true,
    );
  }

  @override
  Future<OpenedWorkspace> open(
    String hostId,
    String path,
    WorkspaceAgent agent,
  ) async {
    final host = _host(hostId);
    final Map<String, dynamic> result;
    try {
      // Starting an agent can take a while (npx downloads it the first time).
      result = await host.call('session/new', {
        'cwd': path,
        'mcpServers': const <Object>[],
        '_meta': {
          'baya': {'agent': agent.id},
        },
      }, const Duration(minutes: 3));
    } catch (error) {
      throw WorkspaceFailure('$error');
    }
    final sessionId = result['sessionId'] as String;
    return OpenedWorkspace(
      hostId: host.key,
      hostLabel: host.host.label,
      path: path,
      sessionId: sessionId,
      name: host.session(sessionId)?.title ?? folderName(path),
      agent: agent,
    );
  }
}
