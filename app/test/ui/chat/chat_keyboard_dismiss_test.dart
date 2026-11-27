import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _messages = <ChatMessage>[
  for (var i = 0; i < 40; i++)
    AssistantMsg(id: 'a$i', text: 'Line $i of a long conversation.'),
];

void main() {
  testWidgets('the chat moving on its own leaves another field its keyboard', (
    tester,
  ) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Column(
            children: [
              TextField(key: const Key('other'), focusNode: field),
              Expanded(
                child: ChatMessageList(messages: _messages, working: false),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();
    expect(field.hasFocus, isTrue);

    // A keyboard opening over the chat moves its list without a finger.
    final list = tester.state<ScrollableState>(find.byType(Scrollable).last);
    list.position.jumpTo(200);
    await tester.pump();
    expect(field.hasFocus, isTrue);

    // A finger dragging the chat still puts the keyboard away.
    await tester.drag(find.byType(ChatMessageList), const Offset(0, -300));
    await tester.pump();
    expect(field.hasFocus, isFalse);
  });
}
