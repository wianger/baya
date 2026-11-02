import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/widgets/tool_run_group.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  test('one copy owner belongs to the last assistant segment per turn', () {
    final messages = <ChatMessage>[
      const UserMsg(id: 'user-1', text: 'First request'),
      const AssistantMsg(id: 'assistant-1-a', text: 'Starting'),
      const ToolEvent(
        id: 'tool-1',
        toolCallId: 'tool-1',
        tool: 'command',
        args: <String, Object?>{},
        status: ToolEventStatus.completed,
      ),
      const AssistantMsg(id: 'assistant-1-b', text: 'Finished'),
      const UserMsg(id: 'user-2', text: 'Second request'),
      const AssistantMsg(id: 'assistant-2', text: 'Done'),
    ];

    final owners = assistantCopyOwnersForTurns(messages);
    expect(owners.map((message) => message.id), {
      'assistant-1-b',
      'assistant-2',
    });
  });

  test('thinking and tool boundaries keep only the newest segment', () {
    final messages = <ChatMessage>[
      const UserMsg(id: 'user-1', text: 'Do the thing'),
      const AssistantMsg(id: 'a-1', text: 'Looking'),
      const ThinkingMsg(id: 't-1', text: 'reasoning', complete: true),
      const AssistantMsg(id: 'a-2', text: 'Running the command'),
      const ToolEvent(
        id: 'tool-1',
        toolCallId: 'tool-1',
        tool: 'command',
        args: <String, Object?>{},
        status: ToolEventStatus.completed,
      ),
      const AssistantMsg(id: 'a-3', text: 'Done'),
    ];

    final owners = assistantCopyOwnersForTurns(messages);
    expect(owners, hasLength(1));
    expect(owners.single.text, 'Done');
  });

  test('steering input and legacy duplicate ids keep one copy owner', () {
    final messages = <ChatMessage>[
      const UserMsg(id: 'user-1', text: 'Initial request'),
      const AssistantMsg(id: 'user-1', text: 'Starting'),
      const ToolEvent(
        id: 'tool-1',
        toolCallId: 'tool-1',
        tool: 'command',
        args: <String, Object?>{},
        status: ToolEventStatus.completed,
      ),
      const AssistantMsg(id: 'user-1', text: 'Intermediate'),
      const UserMsg(id: 'steer-1', text: 'Also check this', steering: true),
      const AssistantMsg(id: 'user-1', text: 'Finished'),
    ];

    final owners = assistantCopyOwnersForTurns(messages);
    expect(owners, hasLength(1));
    expect(owners.single.text, 'Finished');
  });

  test('consecutive calls group; calls split by text stay separate', () {
    const a = ToolEvent(
      id: 'tool-1',
      toolCallId: 'cmd-1',
      tool: 'command',
      args: {'command': 'git status'},
      status: ToolEventStatus.completed,
    );
    const b = ToolEvent(
      id: 'tool-2',
      toolCallId: 'cmd-2',
      tool: 'command',
      args: {'command': 'git diff'},
      status: ToolEventStatus.completed,
    );
    const c = ToolEvent(
      id: 'tool-3',
      toolCallId: 'cmd-3',
      tool: 'command',
      args: {'command': 'ls'},
      status: ToolEventStatus.completed,
    );

    final items = toolRunItemsForMessages([
      const UserMsg(id: 'u1', text: 'Go'),
      a,
      b,
      const AssistantMsg(id: 'a1', text: 'Now the next one'),
      c,
    ]);

    expect(items.length, 4);
    expect(items[0], isA<UserMsg>());
    expect(items[1], isA<ToolRunItem>());
    expect((items[1] as ToolRunItem).tools, [a, b]);
    expect(items[2], isA<AssistantMsg>());
    // A lone call renders as the plain card, not as a group.
    expect(items[3], same(c));
  });

  testWidgets('multiple tools collapse into one row and open a grouped sheet', (
    tester,
  ) async {
    const tools = [
      ToolEvent(
        id: 'tool-1',
        toolCallId: 'cmd-1',
        tool: 'command',
        args: {
          'description': 'Post review findings on PR 371',
          'command': 'gh pr review 371 --comment',
        },
        status: ToolEventStatus.completed,
      ),
      ToolEvent(
        id: 'tool-2',
        toolCallId: 'agent-1',
        tool: 'message_agent',
        args: {'prompt': 'PR 371 fix round 1'},
        status: ToolEventStatus.completed,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: ToolRunGroup(tools: tools)),
      ),
    );
    expect(find.text('Ran a command, used a tool'), findsOneWidget);
    // The collapsed row now names what ran instead of only counting calls.
    expect(find.text('gh pr review 371 --comment  ·  +1 more'), findsOneWidget);
    await tester.tap(find.text('Ran a command, used a tool'));
    await tester.pumpAndSettle();
    expect(find.text('Post review findings on PR 371'), findsOneWidget);
    expect(find.text('Messaged agent'), findsOneWidget);
    expect(find.text('gh pr review 371 --comment'), findsOneWidget);
  });

  testWidgets('the consecutive tool picker floats away from screen edges', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const tools = [
      ToolEvent(
        id: 'tool-1',
        toolCallId: 'cmd-1',
        tool: 'command',
        args: {'command': 'git status'},
        status: ToolEventStatus.completed,
      ),
      ToolEvent(
        id: 'tool-2',
        toolCallId: 'cmd-2',
        tool: 'command',
        args: {'command': 'git diff'},
        status: ToolEventStatus.completed,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: ToolRunGroup(tools: tools)),
      ),
    );

    await tester.tap(find.byKey(const Key('tool-run-group')));
    await tester.pumpAndSettle();

    final sheet = tester.getRect(
      find.byKey(const ValueKey('tool-run-list-sheet')),
    );
    expect(sheet.left, closeTo(12, .01));
    expect(sheet.right, closeTo(378, .01));
  });

  testWidgets('a lone tool keeps its readable content in the transcript', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const tool = ToolEvent(
      id: 'tool-1',
      toolCallId: 'cmd-1',
      tool: 'command',
      args: {'command': 'git status'},
      result: 'working tree clean',
      status: ToolEventStatus.completed,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: ToolRunGroup(tools: [tool])),
      ),
    );

    expect(find.byKey(const ValueKey('activity-detail-sheet')), findsNothing);
    expect(find.text('Ran command'), findsOneWidget);
    expect(find.text('git status'), findsOneWidget);
    expect(find.text('working tree clean'), findsOneWidget);
  });

  testWidgets('a single tool exposes its final detail without an extra tap', (
    tester,
  ) async {
    const tool = ToolEvent(
      id: 'tool-1',
      toolCallId: 'cmd-1',
      tool: 'command',
      args: {'command': 'git status'},
      result: 'working tree clean',
      status: ToolEventStatus.completed,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: ToolRunGroup(tools: [tool])),
      ),
    );

    expect(find.text('Command'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('tool-command')),
        matching: find.text('git status'),
      ),
      findsOneWidget,
    );
    expect(find.text('Result'), findsOneWidget);
    expect(find.text('working tree clean'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-detail-sheet')), findsNothing);
  });

  testWidgets('a single agent message keeps its meaningful title and icon', (
    tester,
  ) async {
    const tool = ToolEvent(
      id: 'agent-1',
      toolCallId: 'agent-1',
      tool: 'message_agent',
      args: {'prompt': 'Review the latest patch'},
      status: ToolEventStatus.completed,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: ToolRunGroup(tools: [tool])),
      ),
    );

    expect(find.text('Messaged agent'), findsOneWidget);
    expect(find.text('Used a tool'), findsNothing);
    expect(find.byIcon(LucideIcons.send), findsOneWidget);
  });

  testWidgets('a lone edit shows its path and semantic diff immediately', (
    tester,
  ) async {
    const tool = ToolEvent(
      id: 'edit-1',
      toolCallId: 'edit-1',
      tool: 'edit',
      args: {
        'path': 'lib/main.dart',
        'edits': [
          {'oldText': 'old title', 'newText': 'new title'},
        ],
      },
      status: ToolEventStatus.completed,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: ToolRunGroup(tools: [tool])),
      ),
    );

    expect(find.text('Edited file'), findsOneWidget);
    expect(find.textContaining('M lib/main.dart'), findsOneWidget);
    expect(find.text('Changes'), findsOneWidget);
    expect(find.textContaining('-old title'), findsOneWidget);
    expect(find.textContaining('+new title'), findsOneWidget);
    expect(find.textContaining('"oldText"'), findsNothing);
  });
}
