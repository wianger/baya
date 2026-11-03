import 'package:app/acp/acp.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:app/ui/chat/widgets/tool_run_group.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ToolEvent tool(
  String id, {
  String title = '',
  ToolKind kind = ToolKind.other,
  ToolEventStatus status = ToolEventStatus.completed,
  List<ToolCallContent> content = const [],
  List<ToolLocation> locations = const [],
  Object? rawInput,
  Object? rawOutput,
}) => ToolEvent(
  id: id,
  toolCallId: id,
  title: title,
  kind: kind,
  status: status,
  content: content,
  locations: locations,
  rawInput: rawInput,
  rawOutput: rawOutput,
);

Widget app(Widget child) => MaterialApp(
  theme: buildLightTheme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('ToolContent', () {
    test('a shell call reads as its command', () {
      final content = ToolContent(
        tool(
          't',
          title: 'Run tests',
          kind: ToolKind.execute,
          rawInput: {'command': 'npm test', 'cwd': '/code'},
          rawOutput: {'stdout': 'ok', 'stderr': 'warn'},
        ),
      );
      expect(content.isCommand, isTrue);
      expect(content.title, 'Run tests');
      expect(content.command, 'npm test');
      expect(content.workingDirectory, '/code');
      expect(content.output.text, 'ok');
      expect(content.output.stderr, 'warn');
      expect(content.inputFields, isEmpty);
    });

    test('an edit shows its diff and path', () {
      final content = ToolContent(
        tool(
          't',
          title: 'Edit main.dart',
          kind: ToolKind.edit,
          content: const [
            ToolCallDiff(
              path: 'lib/main.dart',
              oldText: 'a\nb',
              newText: 'a\nc',
            ),
          ],
        ),
      );
      expect(content.isFileChange, isTrue);
      expect(content.path, 'lib/main.dart');
      expect(content.diffs.single.path, 'lib/main.dart');
      expect(content.diffStats, (added: 1, removed: 1));
    });

    test('text content is the output; no title falls back to the kind', () {
      final content = ToolContent(
        tool(
          't',
          kind: ToolKind.read,
          content: const [ToolCallText(TextContent('file body'))],
          locations: const [ToolLocation('README.md')],
        ),
      );
      expect(content.title, 'Read');
      expect(content.output.text, 'file body');
      expect(content.detailLine, 'README.md');
    });

    test('input reads as labelled fields, not JSON', () {
      final content = ToolContent(
        tool(
          't',
          kind: ToolKind.search,
          rawInput: {
            'pattern': 'redirect',
            'filePath': 'src/auth',
            'globs': ['*.ts', '*.tsx'],
            'limit': 20,
            'empty': '',
          },
        ),
      );
      expect(content.inputFields, [
        (label: 'Pattern', value: 'redirect'),
        (label: 'File path', value: 'src/auth'),
        (label: 'Globs', value: '*.ts, *.tsx'),
        (label: 'Limit', value: '20'),
      ]);
    });

    test('terminal colour codes and redraws are cleaned up', () {
      expect(
        cleanTerminalText('\x1B[32;1mMode\x1B[0m  Name\r\n10%\r55%\r100%'),
        'Mode  Name\n100%',
      );
      expect(cleanTerminalText('\x1B]0;title\x07ok'), 'ok');
    });

    test('a failed call with nothing to show says it failed', () {
      final content = ToolContent(tool('t', status: ToolEventStatus.failed));
      expect(content.error, 'Failed');
    });
  });

  test('an edit counts its added and removed lines', () {
    final stats = ToolContent(
      tool(
        't',
        kind: ToolKind.edit,
        content: const [
          ToolCallDiff(path: 'a.dart', oldText: 'a\nb', newText: 'a\nc\nd'),
        ],
      ),
    ).diffStats;
    expect(stats, (added: 2, removed: 1));
  });

  group('rows', () {
    testWidgets('a lone tool shows its title and output', (tester) async {
      await tester.pumpWidget(
        app(
          ToolRunGroup(
            tools: [
              tool(
                't',
                title: 'List files',
                kind: ToolKind.execute,
                rawInput: {'command': 'ls'},
                content: const [ToolCallText(TextContent('a.txt'))],
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('List files'), findsOneWidget);
      expect(find.textContaining('a.txt'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tool-details-t')));
      await tester.pumpAndSettle();
      expect(find.textContaining('a.txt'), findsWidgets);
    });

    testWidgets('several tools collapse into one row', (tester) async {
      await tester.pumpWidget(
        app(
          ToolRunGroup(
            tools: [
              tool('a', title: 'ls', kind: ToolKind.execute),
              tool('b', title: 'pwd', kind: ToolKind.execute),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tool-run-group')), findsOneWidget);
      expect(find.text('ls'), findsNothing);
      await tester.tap(find.byKey(const Key('tool-run-group')));
      await tester.pumpAndSettle();
      expect(find.text('ls'), findsOneWidget);
      expect(find.text('pwd'), findsOneWidget);
    });

    testWidgets('a call waiting on permission says so', (tester) async {
      await tester.pumpWidget(
        app(
          ToolRunGroup(
            tools: [
              const ToolEvent(
                id: 't',
                toolCallId: 't',
                title: 'Delete build/',
                kind: ToolKind.delete,
                status: ToolEventStatus.pending,
                awaitingApproval: true,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Approval'), findsOneWidget);
    });
  });

  test('startup chatter folds away and empty agent text is dropped', () {
    final items = toolRunItemsForMessages(const [
      AssistantMsg(id: 'a0', text: 'pi v1.5.0\n## Skills'),
      UserMsg(id: 'u1', text: 'Hi'),
      AssistantMsg(id: 'a1', text: '  '),
      AssistantMsg(id: 'a2', text: 'Hello'),
    ]);
    expect(items, hasLength(3));
    expect(items.first, isA<StartupNote>());
    expect((items.last as AssistantMsg).text, 'Hello');
  });

  test('one copy owner per turn, after the last assistant segment', () {
    final owners = assistantCopyOwnersForTurns(const [
      UserMsg(id: 'u1', text: 'First'),
      AssistantMsg(id: 'a1', text: 'Starting'),
      ToolEvent(id: 't1', toolCallId: 't1'),
      AssistantMsg(id: 'a2', text: 'Finished'),
      UserMsg(id: 'u2', text: 'Second'),
      AssistantMsg(id: 'a3', text: 'Done'),
    ]);
    expect(owners.map((m) => m.id), {'a2', 'a3'});
  });
}
