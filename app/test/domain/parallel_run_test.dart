import 'package:app/domain/runs/parallel_run.dart';
import 'package:app/ui/runs/run_page.dart' show plainSnippet;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a run survives being saved, without its start failures', () {
    final run = ParallelRun(
      id: '1',
      hostId: 'epk',
      hostLabel: 'studio',
      folder: r'C:\code\baya',
      createdAt: DateTime.utc(2026, 11, 4, 8),
      workspaceKey: 'epk:workspace:default',
      failures: const ['Pi: npx failed'],
      members: const [
        RunMember(
          sessionId: 's1',
          agentId: 'claude',
          agentLabel: 'Claude Code',
          path: '/wt/claude',
          branch: 'baya/claude',
        ),
        RunMember(
          sessionId: 's2',
          agentId: 'codex',
          agentLabel: 'Codex',
          path: r'C:\code\baya',
        ),
      ],
    );
    final back = ParallelRun.fromJson(run.toJson());
    expect(back.name, 'baya');
    expect(back.createdAt, run.createdAt);
    expect(back.workspaceKey, run.workspaceKey);
    expect(back.failures, isEmpty);
    expect(back.members.map((m) => m.branch), ['baya/claude', null]);
    expect(back.usesWorktrees, isTrue);
  });

  test('a reply previews as plain text', () {
    expect(
      plainSnippet(
        '## Done\n\nAdded a **Dark mode** switch in `Settings`, see '
        '[the PR](https://x/1).\n\n- one\n- two\n```dart\ncode\n```',
      ),
      'Done Added a Dark mode switch in Settings, see the PR. one two',
    );
  });
}
