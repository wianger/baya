import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

String _selectableBody(SelectableText text) =>
    text.data ?? text.textSpan?.toPlainText() ?? '';

TextSpan _lineSpan(SelectableText text, String line) {
  return text.textSpan!.children!.whereType<TextSpan>().singleWhere(
    (span) => span.text == line,
  );
}

const _bashTool = ToolEvent(
  id: 'tc1',
  toolCallId: 'tc1',
  tool: 'Bash',
  args: {'command': 'ls -la'},
);

const _editToolWithHunk = ToolEvent(
  id: 'tc2',
  toolCallId: 'tc4',
  tool: 'edit',
  args: {
    'path': 'app/test/ui/chat/tool_request_card_test.dart',
    'hunks': [
      {
        'lines': [
          {'kind': 'context', 'oldLine': 16, 'newLine': 16, 'text': 'args: {'},
          {'kind': 'remove', 'oldLine': 17, 'text': "  tool: 'Edit',"},
          {'kind': 'add', 'newLine': 17, 'text': "  tool: 'edit',"},
          {'kind': 'context', 'oldLine': 18, 'newLine': 18, 'text': '},'},
        ],
      },
    ],
  },
);

const _codexFileChange = ToolEvent(
  id: 'codex-change',
  toolCallId: 'codex-change',
  tool: 'apply_patch',
  args: {
    'changes': {
      'app/lib/main.dart': {
        'type': 'update',
        'unified_diff': '@@ -1,2 +1,2 @@\n-old title\n+new title\n unchanged',
        'move_path': null,
      },
    },
  },
  result: {
    'changes': {
      'app/lib/main.dart': {
        'type': 'update',
        'unified_diff': '@@ -1,2 +1,2 @@\n-old title\n+new title\n unchanged',
        'move_path': null,
      },
    },
  },
  status: ToolEventStatus.completed,
);

const _gitDiffTool = ToolEvent(
  id: 'git-diff',
  toolCallId: 'git-diff',
  tool: 'command',
  args: {'command': 'git --no-pager diff -- lib/main.dart'},
  result:
      'diff --git a/lib/main.dart b/lib/main.dart\n'
      'index 1234567..89abcde 100644\n'
      '--- a/lib/main.dart\n'
      '+++ b/lib/main.dart\n'
      '@@ -1,2 +1,2 @@\n'
      '-old title\n'
      '+new title\n'
      ' unchanged',
  status: ToolEventStatus.completed,
);

const _plainPlusMinusLog = ToolEvent(
  id: 'plain-log',
  toolCallId: 'plain-log',
  tool: 'command',
  args: {'command': 'cat results.log'},
  result: '+ accepted\n- rejected',
  status: ToolEventStatus.completed,
);

void main() {
  testWidgets('a failed thinking tool keeps its error visible in details', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ToolRequestCard(
          tool: ToolEvent(
            id: 'failed-think',
            toolCallId: 'failed-think',
            tool: 'think',
            args: {'thought': 'Check the project.'},
            status: ToolEventStatus.failed,
            error: 'The tool could not continue.',
          ),
        ),
      ),
    );
    expect(find.text('Failed'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tool-details-failed-think')));
    await tester.pump();
    expect(find.text('The tool could not continue.'), findsOneWidget);
  });

  testWidgets('single call collapses to one row and expands on tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ToolRequestCard(
          tool: ToolEvent(
            id: 'output',
            toolCallId: 'output',
            tool: 'bash',
            args: {'command': 'git status'},
            result: 'Working tree clean',
            status: ToolEventStatus.completed,
          ),
        ),
      ),
    );
    // Collapsed default: the activity label and a dimmed command preview.
    expect(find.text('Ran command'), findsOneWidget);
    expect(find.text('git status'), findsOneWidget);
    // Output stays behind the tap.
    expect(find.text('Working tree clean'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tool-details-output')));
    await tester.pump();
    expect(find.text('Working tree clean'), findsOneWidget);
  });

  testWidgets('command and result copy their own content', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      _wrap(
        const ToolRequestCard(
          tool: ToolEvent(
            id: 'copy-content',
            toolCallId: 'copy-content',
            tool: 'bash',
            args: {'command': 'git status --short'},
            result: ' M app/lib/ui/chat/chat_page.dart',
            status: ToolEventStatus.completed,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('tool-details-copy-content')));
    await tester.pump();

    final commandCopy = find.byKey(
      const ValueKey('tool-copy-copy-content-command'),
    );
    final resultCopy = find.byKey(
      const ValueKey('tool-copy-copy-content-result'),
    );
    expect(commandCopy, findsOneWidget);
    expect(resultCopy, findsOneWidget);

    await tester.tap(
      find.descendant(of: commandCopy, matching: find.text('Copy')),
    );
    await tester.pump();
    expect(
      find.descendant(of: commandCopy, matching: find.text('Copied')),
      findsOneWidget,
    );
    expect((calls.first.arguments as Map)['text'], 'git status --short');

    await tester.tap(
      find.descendant(of: resultCopy, matching: find.text('Copy')),
    );
    await tester.pump();
    expect(
      find.descendant(of: resultCopy, matching: find.text('Copied')),
      findsOneWidget,
    );
    expect(
      (calls.last.arguments as Map)['text'],
      ' M app/lib/ui/chat/chat_page.dart',
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('long output is collapsed behind Show full output', (
    tester,
  ) async {
    final longOutput = List.generate(40, (i) => 'line $i').join('\n');
    final tool = ToolEvent(
      id: 'long',
      toolCallId: 'long',
      tool: 'bash',
      args: {'command': 'git status'},
      status: ToolEventStatus.completed,
      result: longOutput,
    );
    await tester.pumpWidget(_wrap(ToolRequestCard(tool: tool)));
    expect(find.text('Ran command'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tool-details-long')));
    await tester.pump();
    expect(find.text('Show full output'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tool-output-toggle-long')));
    await tester.pump();
    expect(find.text('Show less'), findsOneWidget);
  });
  testWidgets('paused agent approval sends one explicit allow decision', (
    tester,
  ) async {
    ApproveDecision? decision;
    String? id;
    await tester.pumpWidget(
      _wrap(
        ToolRequestCard(
          tool: const ToolEvent(
            id: 'approval',
            toolCallId: 'approval',
            tool: 'commandExecution',
            args: {'command': 'git status', 'approval_required': true},
          ),
          onDecide: (value, choice) {
            id = value;
            decision = choice;
          },
        ),
      ),
    );
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.text('git status'), findsOneWidget);
    expect(find.textContaining('approval_required'), findsNothing);
    expect(find.text('Deny'), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    expect(id, 'approval');
    expect(decision, ApproveDecision.allow);
  });
  group('ToolRequestCard (informational)', () {
    testWidgets('shows tool name and command', (tester) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(find.text('Running command'), findsOneWidget);
      // A lone call renders its command inline — no extra tap needed.
      expect(find.text('ls -la'), findsOneWidget);
    });

    testWidgets('edit renders rich hunks with context lines', (tester) async {
      await tester.pumpWidget(
        _wrap(const ToolRequestCard(tool: _editToolWithHunk)),
      );
      await tester.tap(find.byKey(const ValueKey('tool-details-tc4')));
      await tester.pump();

      final changesFinder = find.descendant(
        of: find.byKey(const Key('tool-changes')),
        matching: find.byType(SelectableText),
      );
      final changes = tester.widget<SelectableText>(changesFinder);
      expect(_selectableBody(changes), contains('   16  args: {'));
      expect(_selectableBody(changes), contains("-  17    tool: 'Edit',"));
      expect(_selectableBody(changes), contains("+  17    tool: 'edit',"));
      expect(_selectableBody(changes), contains('   18  },'));
      expect(
        find.byKey(const ValueKey('tool-copy-tc4-changes')),
        findsOneWidget,
      );
    });

    testWidgets('Codex file changes avoid raw JSON and keep copy inside', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const ToolRequestCard(tool: _codexFileChange)),
      );
      expect(find.text('Edited files'), findsOneWidget);
      expect(find.text('app/lib/main.dart'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tool-details-codex-change')));
      await tester.pump();

      final changesFinder = find.descendant(
        of: find.byKey(const Key('tool-changes')),
        matching: find.byType(SelectableText),
      );
      final changes = tester.widget<SelectableText>(changesFinder);
      expect(_selectableBody(changes), contains('M app/lib/main.dart'));
      expect(_selectableBody(changes), contains('-old title'));
      expect(_selectableBody(changes), contains('+new title'));
      expect(_selectableBody(changes), isNot(contains('"unified_diff"')));
      expect(find.text('Result'), findsNothing);

      final copy = find.byKey(const ValueKey('tool-copy-codex-change-changes'));
      expect(copy, findsOneWidget);
      final body = find
          .descendant(
            of: find.byKey(const Key('tool-changes')),
            matching: find.byType(Container),
          )
          .first;
      final bodyRect = tester.getRect(body);
      final copyRect = tester.getRect(copy);
      expect(
        bodyRect.contains(copyRect.topLeft) &&
            bodyRect.contains(copyRect.bottomRight),
        isTrue,
        reason: 'The copy action belongs inside the framed changes body.',
      );
      expect(
        copyRect.center.dx,
        greaterThan(bodyRect.center.dx),
        reason: 'The copy action belongs at the top-right of the framed body.',
      );
      expect(
        copyRect.top,
        lessThan(bodyRect.top + 40),
        reason: 'The copy action belongs at the top-right of the framed body.',
      );
    });

    testWidgets('git diff output colors semantic lines and preserves headers', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _gitDiffTool)));
      await tester.tap(find.byKey(const ValueKey('tool-details-git-diff')));
      await tester.pump();

      final result = tester.widget<SelectableText>(
        find.descendant(
          of: find.byKey(const Key('tool-result')),
          matching: find.byType(SelectableText),
        ),
      );

      expect(
        _lineSpan(result, '-old title\n').style?.color,
        AppColors.dark.error,
      );
      expect(
        _lineSpan(result, '+new title\n').style?.color,
        AppColors.dark.success,
      );
      expect(
        _lineSpan(result, '@@ -1,2 +1,2 @@\n').style?.color,
        AppColors.dark.muted,
      );
      expect(
        _lineSpan(result, '--- a/lib/main.dart\n').style?.color,
        AppColors.dark.muted,
      );
      expect(
        _lineSpan(result, '+++ b/lib/main.dart\n').style?.color,
        AppColors.dark.muted,
      );
      expect(_lineSpan(result, ' unchanged').style?.color, isNull);
    });

    testWidgets('plus and minus log lines stay plain outside git diff', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const ToolRequestCard(tool: _plainPlusMinusLog)),
      );
      await tester.tap(find.byKey(const ValueKey('tool-details-plain-log')));
      await tester.pump();

      final result = tester.widget<SelectableText>(
        find.descendant(
          of: find.byKey(const Key('tool-result')),
          matching: find.byType(SelectableText),
        ),
      );
      expect(result.data, '+ accepted\n- rejected');
      expect(result.textSpan, isNull);
    });

    testWidgets('agent messages use prose type instead of terminal type', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const ToolRequestCard(
            tool: ToolEvent(
              id: 'agent-message',
              toolCallId: 'agent-message',
              tool: 'message_agent',
              args: {'prompt': 'Fix the failing test.'},
              result: 'Review agent started.',
              status: ToolEventStatus.completed,
            ),
          ),
        ),
      );
      expect(find.text('Messaged agent'), findsOneWidget);
      expect(find.text('Fix the failing test.'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('tool-details-agent-message')),
      );
      await tester.pump();

      final input = tester.widget<SelectableText>(
        find.descendant(
          of: find.byKey(const Key('tool-input')),
          matching: find.byType(SelectableText),
        ),
      );
      final result = tester.widget<SelectableText>(
        find.descendant(
          of: find.byKey(const Key('tool-result')),
          matching: find.byType(SelectableText),
        ),
      );
      expect(input.style?.fontFamily, kSansFamily);
      expect(result.style?.fontFamily, kSansFamily);
    });

    testWidgets('pending state shows RUNNING and no Allow/Deny buttons', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      expect(find.text('Running command'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      expect(find.textContaining('60s'), findsNothing);
    });

    testWidgets('completed state shows Completed', (tester) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
      expect(find.text('Ran command'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tool-details-tc1')));
      await tester.pump();
      expect(find.text('Completed without output.'), findsOneWidget);
    });

    testWidgets('denied state shows DENIED label', (tester) async {
      const denied = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.denied,
        error: 'user denied',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: denied)));
      expect(find.text('Denied'), findsOneWidget);
    });

    testWidgets('allowed state shows RUNNING (still in flight)', (
      tester,
    ) async {
      const allowed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.allowed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: allowed)));
      expect(find.text('Running command'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
    });

    // Ordinary activity stays subtle; failures remain emphasized.
    // Assert the expanded outcome color (the same semantic token
    // is used by the activity header).
    Color? outcomeColor(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text)).style?.color;

    testWidgets('completed without output stays quiet', (tester) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: done)));
      await tester.tap(find.byKey(const ValueKey('tool-details-tc1')));
      await tester.pump();
      expect(
        outcomeColor(tester, 'Completed without output.'),
        AppColors.dark.muted,
      );
    });

    testWidgets('failed status and error use the error color', (tester) async {
      const failed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'exit 1'},
        status: ToolEventStatus.failed,
        error: 'command failed: exit 1',
      );
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: failed)));
      expect(find.text('Failed'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tool-details-tc1')));
      await tester.pump();
      final error = tester.widget<SelectableText>(
        find.descendant(
          of: find.byKey(const Key('tool-error')),
          matching: find.byType(SelectableText),
        ),
      );
      expect(error.style?.color, AppColors.dark.error);
      expect(find.byKey(const ValueKey('tool-copy-tc1-error')), findsOneWidget);
      expect(outcomeColor(tester, 'Failed'), AppColors.dark.error);
    });

    testWidgets('running shows a quiet progress indicator', (tester) async {
      // pending defaults
      await tester.pumpWidget(_wrap(const ToolRequestCard(tool: _bashTool)));
      await tester.tap(find.byKey(const ValueKey('tool-details-tc1')));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tool-details-tc1')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
    });
  });
}
