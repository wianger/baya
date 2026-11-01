import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpList(
  WidgetTester tester, {
  required bool working,
  StreamingMessage? streaming,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: ChatMessageList(
          messages: const [
            UserMsg(id: 'u1', text: 'Keep working until the task is finished.'),
            AssistantMsg(id: 'a1', text: 'I am checking the project now.'),
          ],
          streaming: streaming,
          working: working,
          onDecide: (_, _) {},
        ),
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
                tool: 'command',
                args: {'command': 'flutter test'},
                status: ToolEventStatus.completed,
              ),
              AssistantMsg(id: 'u1', text: 'The fix is complete.'),
            ],
            streaming: null,
            working: false,
            onDecide: (_, _) {},
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
      greaterThan(tester.getRect(find.byKey(const ValueKey('a1'))).bottom),
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

  testWidgets('streaming text uses its cursor without a duplicate loader', (
    tester,
  ) async {
    await _pumpList(
      tester,
      working: true,
      streaming: const StreamingMessage(
        inReplyTo: 'u1',
        buffer: 'I found the first part of the answer.',
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('streaming-cursor')), findsOneWidget);
    expect(find.byKey(const Key('agent-working-indicator')), findsNothing);
    expect(find.byKey(const Key('agent-working')), findsNothing);
  });
}
