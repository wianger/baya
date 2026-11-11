import 'package:app/acp/acp.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpList(
  WidgetTester tester, {
  required bool working,
  List<ChatMessage> messages = const [
    UserMsg(id: 'u1', text: 'Keep working until the task is finished.'),
    ToolEvent(id: 't1', toolCallId: 't1', title: 'Read pubspec.yaml'),
  ],
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: ChatMessageList(messages: messages, working: working),
      ),
    ),
  );
}

void main() {
  testWidgets('tool-separated segments expose exactly one copy action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(
          body: ChatMessageList(
            messages: [
              UserMsg(id: 'u1', text: 'Fix it'),
              AssistantMsg(id: 'u1', text: 'I will inspect the code.'),
              ToolEvent(
                id: 'tool-1',
                toolCallId: 'tool-1',
                title: 'flutter test',
                kind: ToolKind.execute,
                status: ToolEventStatus.completed,
              ),
              AssistantMsg(id: 'u1', text: 'The fix is complete.'),
            ],
            working: false,
          ),
        ),
      ),
    );
    await tester.pump();

    final assistantCopy = find.byKey(const Key('assistant-copy'));
    expect(assistantCopy, findsOneWidget);
    expect(find.byTooltip('Copy'), findsOneWidget);
  });

  testWidgets('working turn shows a loading row at the newest position', (
    tester,
  ) async {
    await _pumpList(tester, working: true);
    await tester.pump();

    final indicator = find.byKey(const Key('agent-working-indicator'));
    expect(indicator, findsOneWidget);
    expect(find.byKey(const Key('streaming-cursor')), findsNothing);
    expect(
      tester.getRect(indicator).top,
      greaterThan(tester.getRect(find.byKey(const ValueKey('u1'))).bottom),
    );
  });

  testWidgets('loading row disappears when the agent finishes', (tester) async {
    await _pumpList(tester, working: true);
    await tester.pump();
    expect(find.byKey(const Key('agent-working-indicator')), findsOneWidget);

    await _pumpList(tester, working: false);
    await tester.pump();
    expect(find.byKey(const Key('agent-working-indicator')), findsNothing);
  });

  testWidgets('a reply being written keeps the loader and has no actions', (
    tester,
  ) async {
    const messages = [
      UserMsg(id: 'u0', text: 'Earlier'),
      AssistantMsg(id: 'a0', text: 'Earlier answer.'),
      UserMsg(id: 'u1', text: 'Question'),
      AssistantMsg(id: 'a1', text: 'I found the first part of the answer.'),
    ];
    await _pumpList(tester, working: true, messages: messages);
    await tester.pump();
    expect(find.text('I found the first part of the answer.'), findsOneWidget);
    expect(find.byKey(const Key('agent-working-indicator')), findsOneWidget);
    // Only the finished turn offers copy and read-aloud.
    expect(find.byTooltip('Copy'), findsOneWidget);
    expect(find.byKey(const Key('assistant-speak')), findsOneWidget);

    await _pumpList(tester, working: false, messages: messages);
    await tester.pump();
    expect(find.byKey(const Key('agent-working-indicator')), findsNothing);
    expect(find.byTooltip('Copy'), findsNWidgets(2));
    expect(find.byKey(const Key('assistant-speak')), findsNWidgets(2));
  });
}
