import 'package:app/acp/acp.dart' show ToolKind;
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_message_list.dart';
import 'package:app/ui/chat/widgets/tool_run_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _list(List<ChatMessage> messages, {bool working = false}) => MaterialApp(
  home: Scaffold(
    body: ChatMessageList(messages: messages, working: working),
  ),
);

void main() {
  testWidgets('an opened thought stays open as new rows arrive', (
    tester,
  ) async {
    const history = <ChatMessage>[
      UserMsg(id: 'u1', text: 'Why does login fail?'),
      ThinkingMsg(id: 't1', text: 'The token looks expired.'),
      AssistantMsg(id: 'a1', text: 'The token expired.'),
    ];
    await tester.pumpWidget(_list(history));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('thinking-disclosure')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('thinking-detail')), findsOneWidget);

    // A new prompt, the working row and a reply: every index shifts.
    await tester.pumpWidget(
      _list(const [
        ...history,
        UserMsg(id: 'u2', text: 'Fix it'),
      ], working: true),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('thinking-detail')), findsOneWidget);

    await tester.pumpWidget(
      _list(const [
        ...history,
        UserMsg(id: 'u2', text: 'Fix it'),
        AssistantMsg(id: 'a2', text: 'Done.'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('thinking-detail')), findsOneWidget);
  });

  testWidgets('an opened tool card stays open when the next tool joins it', (
    tester,
  ) async {
    const read = ToolEvent(
      id: 'tool-c1',
      toolCallId: 'c1',
      title: 'Read login.ts',
      kind: ToolKind.read,
      status: ToolEventStatus.completed,
    );
    await tester.pumpWidget(_list(const [UserMsg(id: 'u1', text: 'Go'), read]));
    await tester.pumpAndSettle();
    final card = find.byType(ToolRunGroup);
    final before = tester.state(card);
    await tester.pumpWidget(
      _list(const [
        UserMsg(id: 'u1', text: 'Go'),
        read,
        ToolEvent(
          id: 'tool-c2',
          toolCallId: 'c2',
          title: 'Edit login.ts',
          kind: ToolKind.edit,
          status: ToolEventStatus.completed,
        ),
      ], working: true),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(identical(tester.state(find.byType(ToolRunGroup)), before), isTrue);
  });

  testWidgets('a thought opens and closes under the finger, leaving no gap', (
    tester,
  ) async {
    final messages = <ChatMessage>[
      for (var i = 0; i < 6; i++) ...[
        UserMsg(id: 'u$i', text: 'Question $i'),
        AssistantMsg(id: 'a$i', text: 'Answer $i ' * 20),
      ],
      const UserMsg(id: 'u9', text: 'Why?'),
      ThinkingMsg(
        id: 't1',
        text: List.filled(40, 'A long line of thought.').join('\n'),
      ),
      const AssistantMsg(id: 'a9', text: 'Because.'),
    ];
    await tester.pumpWidget(_list(messages));
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('thinking-disclosure'));
    final top = tester.getRect(header).top;

    // Opening grows downward: the header stays where it was tapped.
    await tester.tap(header);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getRect(header).top, moreOrLessEquals(top, epsilon: 1));
    }
    await tester.pumpAndSettle();
    expect(tester.getRect(header).top, moreOrLessEquals(top, epsilon: 1));

    // Scrolled down into the thought, closing keeps the header in place
    // and the question above it right where it belongs.
    await tester.drag(
      find.byKey(const ValueKey('thinking-detail')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    final shown = tester.getRect(header).top;
    await tester.tap(header);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getRect(header).top, moreOrLessEquals(shown, epsilon: 1));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('thinking-detail')), findsNothing);
    final question = tester.getRect(find.byKey(const ValueKey('u9')));
    expect(tester.getRect(header).top - question.bottom, lessThan(30));
  });
}
