import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ToolEvent command({
    dynamic args = const {},
    dynamic result,
    String? error,
    ToolEventStatus status = ToolEventStatus.completed,
  }) {
    return ToolEvent(
      id: 'tool',
      toolCallId: 'tool',
      tool: 'bash',
      args: args,
      result: result,
      error: error,
      status: status,
    );
  }

  test('command preview prefers the actual command over its description', () {
    final content = ToolContent(
      command(
        args: const {
          'description': 'Inspect the working tree',
          'command': 'git status --short',
          'cwd': '/repo',
        },
      ),
    );

    expect(content.title, 'Inspect the working tree');
    expect(content.preview, 'git status --short');
    expect(content.command, 'git status --short');
    expect(content.workingDirectory, '/repo');
  });

  test('non-command input filters presentation and approval metadata', () {
    final content = ToolContent(
      const ToolEvent(
        id: 'tool',
        toolCallId: 'tool',
        tool: 'message_agent',
        args: {
          'prompt': 'Fix the failing test',
          'title': 'Delegate the fix',
          'kind': 'execute',
          'approval_required': false,
          'approval_decision': 'allow',
        },
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.inputText, 'Fix the failing test');
    expect(content.visibleArguments, {'prompt': 'Fix the failing test'});
    expect(content.title, 'Delegate the fix');
    expect(content.isAgentMessage, isTrue);
    expect(content.usesProseDetails, isTrue);
  });

  test('Codex file changes render as readable per-file diffs', () {
    const changes = {
      'app/lib/main.dart': {
        'type': 'update',
        'unified_diff': '@@ -1,2 +1,2 @@\n-old title\n+new title\n unchanged',
        'move_path': null,
      },
      'app/test/new_test.dart': {
        'type': 'add',
        'content': 'void main() {}\n',
        'move_path': null,
      },
    };
    final content = ToolContent(
      const ToolEvent(
        id: 'file-change',
        toolCallId: 'file-change',
        tool: 'apply_patch',
        args: {'changes': changes},
        result: {'changes': changes},
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.title, 'Edited files');
    expect(content.isFileChange, isTrue);
    expect(content.preview, 'app/lib/main.dart  ·  +1 more');
    expect(
      content.changesText,
      contains('M app/lib/main.dart\n@@ -1,2 +1,2 @@'),
    );
    expect(content.changesText, contains('A app/test/new_test.dart'));
    expect(content.changesText, isNot(contains('"unified_diff"')));
    expect(content.output.isEmpty, isTrue);
  });

  test('file changes read from the result when the host omits arguments', () {
    final content = ToolContent(
      command(
        result: const {
          'changes': {
            'old.dart': {'type': 'rename', 'move_path': 'new.dart'},
            'removed.dart': {'type': 'delete'},
          },
        },
      ),
    );

    expect(content.isFileChange, isTrue);
    expect(content.changesText, contains('R old.dart -> new.dart'));
    expect(content.changesText, contains('D removed.dart'));
    expect(content.output.isEmpty, isTrue);
  });

  test('string arguments work for commands and free-form tools', () {
    const rawCommand = ToolEvent(
      id: 'command',
      toolCallId: 'command',
      tool: 'bash',
      args: 'git status --short',
      status: ToolEventStatus.completed,
    );
    const rawInput = ToolEvent(
      id: 'input',
      toolCallId: 'input',
      tool: 'custom_tool',
      args: 'A plain-text input',
      status: ToolEventStatus.completed,
    );

    expect(ToolContent(rawCommand).command, 'git status --short');
    expect(ToolContent(rawCommand).preview, 'git status --short');
    expect(ToolContent(rawInput).inputText, 'A plain-text input');
    expect(ToolContent(rawInput).preview, 'A plain-text input');
  });

  test('Pi content wrappers unwrap to human text', () {
    final content = ToolContent(
      command(
        args: const {'command': 'dart test'},
        result: const {
          'content': [
            {'type': 'text', 'text': 'first line'},
            {'type': 'text', 'text': 'second line'},
          ],
          'details': {'exit_code': 0},
        },
      ),
    );

    expect(content.output.text, 'first line\nsecond line');
  });

  test('Codex aggregated output and stderr remain separate', () {
    final content = ToolContent(
      command(
        args: const {'command': 'npm test'},
        result: const {
          'aggregatedOutput': '12 tests passed',
          'stderr': 'warning: deprecated option',
        },
      ),
    );

    expect(content.output.text, '12 tests passed');
    expect(content.output.stderr, 'warning: deprecated option');
  });

  test('output aliases and multiline text are preserved', () {
    final fixtures = <dynamic>[
      'line one\nline two',
      {'stdout': 'line one\nline two'},
      {'aggregated_output': 'line one\nline two'},
      {'message': 'line one\nline two'},
    ];

    for (final fixture in fixtures) {
      final content = ToolContent(command(result: fixture));
      expect(content.output.text, 'line one\nline two');
    }
  });

  test('terminal status values do not masquerade as output', () {
    final content = ToolContent(command(result: 'completed'));

    expect(content.output.isEmpty, isTrue);
  });

  test('an error wrapper does not also render as a result blob', () {
    final content = ToolContent(
      command(
        status: ToolEventStatus.failed,
        result: const {'error': 'permission denied'},
      ),
    );

    expect(content.error, 'permission denied');
    expect(content.output.isEmpty, isTrue);
  });

  test('errors are surfaced and failed status stays readable', () {
    final content = ToolContent(
      command(
        status: ToolEventStatus.failed,
        error: 'Process exited with code 1',
        result: const {'stdout': 'building', 'stderr': 'compile error'},
      ),
    );

    expect(content.statusLabel, 'Failed');
    expect(content.error, 'Process exited with code 1');
    expect(content.output.text, 'building');
    expect(content.output.stderr, 'compile error');
  });
}
