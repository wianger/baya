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
        home: Scaffold(
          body: ChatMessageList(
            messages: const [
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

  testWidgets('a reply being written replaces the loader', (tester) async {
    await _pumpList(
      tester,
      working: true,
      messages: const [
        UserMsg(id: 'u1', text: 'Question'),
        AssistantMsg(id: 'a1', text: 'I found the first part of the answer.'),
      ],
    );
    await tester.pump();
    expect(find.text('I found the first part of the answer.'), findsOneWidget);
    expect(find.byKey(const Key('agent-working-indicator')), findsNothing);
  });
}
