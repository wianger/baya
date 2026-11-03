// The compaction system bubble renders the label, the recap summary
// and the reclaimed token count (distinct from user/assistant bubbles).

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, CompactionMsg msg) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CompactionBubble(msg))),
    );
  }

  testWidgets('shows label and summary once done', (tester) async {
    await pump(
      tester,
      const CompactionMsg(
        id: 'c1',
        summary: 'Recapped the long thread',
        done: true,
      ),
    );

    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.text('Recapped the long thread'), findsOneWidget);
  });

  testWidgets('says it is compacting while in progress', (tester) async {
    await pump(tester, const CompactionMsg(id: 'c1'));
    expect(find.text('Compacting the context…'), findsOneWidget);
  });
}
