import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_find.dart';
import 'package:app/ui/chat/chat_message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A long session: 60 turns, the word "migration" only in the first answer.
final _long = <ChatMessage>[
  for (var i = 0; i < 60; i++) ...[
    UserMsg(id: 'u$i', text: 'Step $i, please'),
    AssistantMsg(
      id: 'a$i',
      text: i == 0
          ? 'The database migration is in db/0042.sql.'
          : 'Done with step $i.\n\nNothing else changed.',
    ),
  ],
];

void main() {
  test('finds what was asked and answered, newest first, ignoring case', () {
    const messages = <ChatMessage>[
      UserMsg(id: 'u1', text: 'Fix the Login page'),
      ThinkingMsg(id: 't1', text: 'login is broken'),
      AssistantMsg(id: 'a1', text: 'The login form posts twice.'),
      UserMsg(id: 'u2', text: 'thanks'),
    ];
    expect(findMatches(messages, 'LOGIN'), ['a1', 'u1']);
    expect(findMatches(messages, '  '), isEmpty);
    expect(findMatches(messages, 'nowhere'), isEmpty);
  });

  test('stepping wraps around both ways', () {
    const messages = <ChatMessage>[
      UserMsg(id: 'u1', text: 'one'),
      UserMsg(id: 'u2', text: 'one more'),
      UserMsg(id: 'u3', text: 'one again'),
    ];
    final find = ChatFind()
      ..show()
      ..search('one');
    expect(find.current(messages), 'u3');
    find.step(messages, older: true);
    expect(find.current(messages), 'u2');
    find.step(messages, older: false);
    find.step(messages, older: false);
    expect(find.current(messages), 'u1');
    find.close();
    expect(find.current(messages), isNull);
    expect(find.query, isEmpty);
  });

  testWidgets('a hit far back is scrolled into view and outlined', (
    tester,
  ) async {
    Widget list(String? focus) => MaterialApp(
      home: Scaffold(
        body: ChatMessageList(messages: _long, working: false, focus: focus),
      ),
    );
    await tester.pumpWidget(list(null));
    await tester.pumpAndSettle();
    final hit = find.textContaining('db/0042.sql', findRichText: true);
    expect(hit, findsNothing);

    await tester.pumpWidget(list('a0'));
    await tester.pumpAndSettle();
    expect(hit, findsOneWidget);
    final box = tester.getRect(hit);
    final screen = tester.getRect(find.byType(Scaffold));
    expect(screen.overlaps(box), isTrue);
    expect(find.byKey(const Key('chat-find-hit')), findsOneWidget);
  });

  testWidgets('the bar counts hits and steps through them', (tester) async {
    final finder = ChatFind()..show();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: finder,
            builder: (_, _) => ChatFindBar(find: finder, messages: _long),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('chat-find-field')), 'step 1');
    await tester.pump();
    // "step 1", "step 10" … "step 19": the request and the answer of each.
    expect(find.text('1/22'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-find-older')));
    await tester.pump();
    expect(find.text('2/22'), findsOneWidget);
    expect(finder.current(_long), 'u19');

    await tester.enterText(find.byKey(const Key('chat-find-field')), 'zzz');
    await tester.pump();
    expect(find.byKey(const Key('chat-find-count')), findsOneWidget);
    expect(find.text('1/22'), findsNothing);
  });
}
