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

    expect(content.title, 'Edited 2 files');
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

  test('Pi edits render oldText and newText as a semantic diff', () {
    final content = ToolContent(
      const ToolEvent(
        id: 'edit-old-text',
        toolCallId: 'edit-old-text',
        tool: 'edit',
        args: {
          'path': 'lib/main.dart',
          'edits': [
            {
              'oldText': 'old title\nunchanged',
              'newText': 'new title\nunchanged',
            },
          ],
        },
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.isFileChange, isTrue);
    expect(content.title, 'Edited file');
    expect(content.preview, 'lib/main.dart');
    expect(content.changesText, contains('M lib/main.dart'));
    expect(content.changesText, contains('-old title'));
    expect(content.changesText, contains('+new title'));
    expect(content.changesText, contains(' unchanged'));
    expect(content.changesText, isNot(contains('"oldText"')));
    expect(content.output.isEmpty, isTrue);
  });

  test('nested DeepSeek edit payload and snake-case replacement keys work', () {
    final content = ToolContent(
      const ToolEvent(
        id: 'deepseek-edit',
        toolCallId: 'deepseek-edit',
        tool: 'Edit file',
        args: {
          'title': 'Edit file',
          'kind': 'edit',
          'rawInput': {
            'file_path': 'docs/readme.md',
            'old_string': 'before',
            'new_string': 'after',
          },
        },
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.title, 'Edited file');
    expect(content.path, 'docs/readme.md');
    expect(content.changesText, contains('-before'));
    expect(content.changesText, contains('+after'));
    expect(content.inputText, isNull);
  });

  test('multiple Pi edits stay distinct instead of becoming raw JSON', () {
    final content = ToolContent(
      const ToolEvent(
        id: 'multi-edit',
        toolCallId: 'multi-edit',
        tool: 'edit',
        args: {
          'path': 'lib/app.dart',
          'edits': [
            {'oldText': 'one', 'newText': 'two'},
            {'oldText': 'red', 'newText': 'blue'},
          ],
        },
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.changesText, contains('@@ edit 1 @@'));
    expect(content.changesText, contains('@@ edit 2 @@'));
    expect(content.changesText, isNot(contains('"edits"')));
  });

  test('read and search metadata are summarized as human input', () {
    final read = ToolContent(
      const ToolEvent(
        id: 'read',
        toolCallId: 'read',
        tool: 'read',
        args: {'path': 'lib/main.dart', 'offset': 10, 'limit': 5},
        status: ToolEventStatus.completed,
      ),
    );
    final search = ToolContent(
      const ToolEvent(
        id: 'search',
        toolCallId: 'search',
        tool: 'Search files',
        args: {'query': 'ToolContent', 'path': 'app/lib'},
        status: ToolEventStatus.completed,
      ),
    );

    expect(read.title, 'Read file');
    expect(read.inputLabel, 'File');
    expect(read.inputText, 'lib/main.dart\nlines 10-14');
    expect(search.title, 'Searched files');
    expect(search.inputLabel, 'Search');
    expect(search.inputText, 'ToolContent\nin app/lib');
  });

  test('unknown scalar arguments avoid a JSON-first presentation', () {
    final content = ToolContent(
      const ToolEvent(
        id: 'unknown',
        toolCallId: 'unknown',
        tool: 'custom_lookup',
        args: {'query': 'needle', 'scope': 3, 'enabled': true},
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.inputText, 'needle\nscope: 3\nenabled: true');
    expect(content.inputText, isNot(contains('{')));
  });

  test('edits suppress redundant completion text from the result', () {
    final content = ToolContent(
      const ToolEvent(
        id: 'edit-result',
        toolCallId: 'edit-result',
        tool: 'edit',
        args: {
          'path': 'lib/main.dart',
          'edits': [
            {'oldText': 'before', 'newText': 'after'},
          ],
        },
        result: 'Successfully replaced text in lib/main.dart',
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.changesText, contains('-before'));
    expect(content.output.isEmpty, isTrue);
  });

  test('agent bodies and delivery results stay prose instead of JSON', () {
    final content = ToolContent(
      const ToolEvent(
        id: 'agent',
        toolCallId: 'agent',
        tool: 'agent_send',
        args: {
          'to': 'reviewer',
          'body': {'message': 'Check the diff.'},
        },
        result: {'status': 'received', 'target': 'reviewer'},
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.inputText, 'To reviewer\n\nCheck the diff.');
    expect(content.output.text, 'Delivered to reviewer.');
    expect(content.output.text, isNot(contains('{')));
  });

  test('DeepSeek raw output content wrappers become readable text', () {
    final content = ToolContent(
      const ToolEvent(
        id: 'deepseek-read',
        toolCallId: 'deepseek-read',
        tool: 'Read file',
        args: {
          'rawInput': {'path': 'README.md'},
        },
        result: {
          'rawOutput': {
            'content': [
              {'type': 'text', 'text': '# Baya'},
            ],
          },
        },
        status: ToolEventStatus.completed,
      ),
    );

    expect(content.title, 'Read file');
    expect(content.inputText, 'README.md');
    expect(content.output.text, '# Baya');
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
