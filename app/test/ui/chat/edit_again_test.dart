import 'dart:async';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/chat_message_list.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a sent message goes back to the composer to edit', (
    tester,
  ) async {
    final drafts = StreamController<UserMsg>.broadcast();
    addTearDown(drafts.close);
    UserMsg? edited;
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ChatMessageList(
                  messages: const [
                    UserMsg(id: 'u1', text: 'Add a dark mode toggle'),
                    UserMsg(
                      id: 'u2',
                      text: 'queued one',
                      status: UserMsgStatus.pending,
                    ),
                  ],
                  working: false,
                  onEdit: (message) {
                    edited = message;
                    drafts.add(message);
                  },
                ),
              ),
              InputBar(onSend: sent.add, drafts: drafts.stream),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    // The queued spinner never settles. A queued message has no actions yet.
    expect(find.byKey(const Key('user-edit')), findsOneWidget);
    await tester.tap(find.byKey(const Key('user-edit')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(edited?.id, 'u1');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Add a dark mode toggle');

    await tester.enterText(find.byType(TextField), 'Add a dark mode switch');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 600));
    expect(sent, ['Add a dark mode switch']);
  });

  testWidgets('copy puts the text on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            messages: const [UserMsg(id: 'u1', text: 'hello')],
            working: false,
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('user-copy')));
    await tester.pump();
    expect(copied, 'hello');
    await tester.pump(const Duration(seconds: 3));
  });
}
