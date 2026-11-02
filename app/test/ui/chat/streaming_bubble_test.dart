// Streaming shows an animated working row before the first text chunk and a
// blinking cursor once response text is present.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, StreamingMessage m) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: StreamingBubble(m))),
    );
  }

  testWidgets('empty buffer shows the animated working indicator', (
    tester,
  ) async {
    await pump(tester, const StreamingMessage(inReplyTo: 'x'));
    await tester.pump();
    expect(find.byKey(const Key('agent-working-indicator')), findsOneWidget);
    expect(find.byKey(const Key('streaming-cursor')), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('working indicator dots animate between frames', (tester) async {
    await pump(tester, const StreamingMessage(inReplyTo: 'x'));
    await tester.pump();
    final dot = find.byKey(const ValueKey('agent-working-dot-0'));
    final before = List<double>.of(
      tester.widget<Transform>(dot).transform.storage,
    );
    await tester.pump(const Duration(milliseconds: 260));
    final after = List<double>.of(
      tester.widget<Transform>(dot).transform.storage,
    );
    expect(after, isNot(equals(before)));
  });

  testWidgets('cursor sits one line BELOW the response (not inline)', (
    tester,
  ) async {
    await pump(
      tester,
      const StreamingMessage(inReplyTo: 'x', buffer: 'a long enough reply'),
    );
    await tester.pump();
    expect(find.byType(AgentMarkdown), findsOneWidget);
    expect(find.byKey(const Key('agent-working-indicator')), findsNothing);
    final md = tester.getRect(find.byType(AgentMarkdown));
    final cursor = tester.getRect(find.byKey(const Key('streaming-cursor')));
    // Below the rendered markdown, and left-aligned — never floating aside.
    expect(cursor.top, greaterThanOrEqualTo(md.bottom - 0.5));
    expect(cursor.left, closeTo(md.left, 1));
  });
}
