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

  test('agent ids map to their labels', () {
    expect(workspaceAgentLabel('deepseek'), 'DeepSeek');
    expect(workspaceAgentLabel('pi'), 'Pi');
    expect(workspaceAgentLabel('opencode'), 'Opencode');
    expect(workspaceAgentLabel(null), '');
  });
}
