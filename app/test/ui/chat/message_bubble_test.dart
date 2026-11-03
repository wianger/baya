// Agent output (AssistantBubble) must use the FULL content width, not the old
// 340px cap (user-reported: markdown reply not filling the horizontal space).

import 'package:app/acp/acp.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AssistantBubble wraps at the full available width (>340)', (
    tester,
  ) async {
    const longText =
        'This is a sufficiently long agent reply that would have wrapped at '
        'the old 340px cap but should now span the full content width of the '
        'message list so it reads naturally on wide screens.';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: AssistantBubble(AssistantMsg(id: 'a1', text: longText)),
          ),
        ),
      ),
    );
    await tester.pump();

    // Markdown rendered + spanning beyond the old 340px cap.
    expect(find.byType(AgentMarkdown), findsOneWidget);
    final width = tester.getSize(find.byType(AgentMarkdown)).width;
    expect(
      width,
      greaterThan(340),
      reason: 'agent markdown should fill beyond the old 340px cap',
    );
  });

  testWidgets('AssistantBubble is selectable (copyable)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantBubble(AssistantMsg(id: 'a1', text: 'reply')),
        ),
      ),
    );
    await tester.pump();
    // AgentMarkdown wraps the reply in a SelectionArea when selectable.
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('the copy footer is a compact labelled icon action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantBubble(AssistantMsg(id: 'a1', text: 'reply')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('assistant-copy')), findsOneWidget);
    expect(find.byTooltip('Copy'), findsOneWidget);
    expect(find.byKey(const Key('assistant-speak')), findsOneWidget);
    expect(find.byTooltip('Read aloud'), findsOneWidget);
  });

  testWidgets('showCopy=false hides the copy footer', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantBubble(
            AssistantMsg(id: 'a1', text: 'reply'),
            showCopy: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('assistant-copy')), findsNothing);
    expect(find.byKey(const Key('assistant-speak')), findsNothing);
  });

  testWidgets('UserBubble text is selectable (copyable)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(UserMsg(id: 'u1', text: 'my message')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('my message'), findsOneWidget);
  });

  testWidgets('a pending prompt says it is queued', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(
              id: 'u1',
              text: 'normal send',
              status: UserMsgStatus.pending,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('queued…'), findsOneWidget);
  });

  testWidgets('a confirmed prompt has no status line', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(UserMsg(id: 'u1', text: 'sent')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('queued…'), findsNothing);
  });

  testWidgets('notices and plans render', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NoticeBubble(
                NoticeMsg(id: 'n', severity: 'error', text: 'Agent crashed'),
              ),
              PlanCard(
                PlanMsg(
                  id: 'p',
                  entries: [
                    PlanEntry('Write tests', PlanStatus.completed),
                    PlanEntry('Ship it', PlanStatus.inProgress),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Agent crashed'), findsOneWidget);
    expect(find.text('Write tests'), findsOneWidget);
    expect(find.text('Ship it'), findsOneWidget);
  });
}
