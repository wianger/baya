import 'package:app/data/workspaces/agent_catalog.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes future ids, labels, availability and unavailable reasons', () {
    final agents = decodeWorkspaceAgents([
      {
        'id': 'future-agent',
        'name': 'New Agent',
        'available': true,
        'description': 'A new adapter',
      },
      {
        'id': 'offline',
        'name': 'Offline',
        'available': false,
        'reason': 'Sign-in required',
      },
      {'id': 'unnamed', 'available': true},
      {'id': 'future-agent', 'name': 'Duplicate', 'available': true},
      {'id': ''},
      null,
    ]);
    expect(agents.map((agent) => agent.id), [
      'future-agent',
      'offline',
      'unnamed',
    ]);
    expect(agents.first.label, 'New Agent');
    expect(agents.first.description, 'A new adapter');
    expect(agents[1].available, false);
    expect(agents[1].unavailableReason, 'Sign-in required');
    expect(agents.last.label, 'unnamed');
  });

  test(
    'future agents never reuse a legacy Pi room just because its path matches',
    () {
      const future = WorkspaceAgent(id: 'future-agent', label: 'New Agent');
      expect(matchesLegacyWorkspaceAgent('project', future), false);
      expect(matchesLegacyWorkspaceAgent('Codex · project', future), false);
      expect(matchesLegacyWorkspaceAgent('project', WorkspaceAgent.pi), true);
      expect(
        matchesLegacyWorkspaceAgent('Codex · project', WorkspaceAgent.codex),
        true,
      );
      expect(matchesLegacyWorkspaceAgent('DeepSeek · project', future), false);
      expect(
        matchesLegacyWorkspaceAgent(
          'DeepSeek · project',
          WorkspaceAgent.deepseek,
        ),
        true,
      );
      expect(workspaceSessionTitle('DeepSeek · project'), 'project');
      expect(workspaceAgentLabelForRoom('DeepSeek · project'), 'DeepSeek');
    },
  );
}
