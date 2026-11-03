import 'package:app/acp/acp.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

SessionUpdate u(Map<String, dynamic> json) => SessionUpdate.fromJson(json);

Map<String, dynamic> chunk(String kind, String text, [String? id]) => {
  'sessionUpdate': kind,
  'content': {'type': 'text', 'text': text},
  'messageId': ?id,
};

void main() {
  test('startup chatter is kept apart from the reply that follows', () {
    final t = Transcript()
      ..apply(
        u({
          ...chunk('agent_message_chunk', 'pi v1.5'),
          '_meta': {
            'baya': {'startup': true},
          },
        }),
      )
      ..apply(u(chunk('agent_message_chunk', 'Hello')));
    final rows = t.messages.whereType<AssistantMsg>().toList();
    expect(rows.map((m) => (m.text, m.startup)), [
      ('pi v1.5', true),
      ('Hello', false),
    ]);
  });

  test('streamed chunks fold into one message per role', () {
    final t = Transcript()
      ..apply(u(chunk('user_message_chunk', 'Fix it', 'm1')))
      ..apply(u(chunk('agent_thought_chunk', 'Look')))
      ..apply(u(chunk('agent_thought_chunk', 'ing')))
      ..apply(u(chunk('agent_message_chunk', 'Hel')))
      ..apply(u(chunk('agent_message_chunk', 'lo')));
    final rows = t.messages;
    expect(rows, hasLength(3));
    expect((rows[0] as UserMsg).text, 'Fix it');
    expect(
      rows[1],
      isA<ThinkingMsg>().having((m) => m.text, 'text', 'Looking'),
    );
    // Thinking is complete once something else arrives.
    expect((rows[1] as ThinkingMsg).complete, isTrue);
    expect((rows[2] as AssistantMsg).text, 'Hello');
  });

  test('a pending prompt is replaced by its echo, keeping the image', () {
    const image = MessageImage(data: 'AAAA', mime: 'image/jpeg');
    final t = Transcript()
      ..addPending(
        const UserMsg(
          id: 'm1',
          text: 'Look',
          status: UserMsgStatus.pending,
          image: image,
        ),
      );
    expect((t.messages.single as UserMsg).status, UserMsgStatus.pending);
    t
      ..apply(u(chunk('user_message_chunk', 'Look', 'm1')))
      ..apply(
        u({
          'sessionUpdate': 'user_message_chunk',
          'content': {
            'type': 'image',
            'data': 'AAAA',
            'mimeType': 'image/jpeg',
          },
          'messageId': 'm1',
        }),
      );
    final row = t.messages.single as UserMsg;
    expect(row.status, UserMsgStatus.confirmed);
    expect(row.image, image);
  });

  test('tool calls are patched in place', () {
    final t = Transcript()
      ..apply(
        u({
          'sessionUpdate': 'tool_call',
          'toolCallId': 't1',
          'title': 'Run tests',
          'kind': 'execute',
          'status': 'pending',
          'rawInput': {'command': 'npm test'},
        }),
      )
      ..apply(
        u({
          'sessionUpdate': 'tool_call_update',
          'toolCallId': 't1',
          'status': 'completed',
          'content': [
            {
              'type': 'content',
              'content': {'type': 'text', 'text': 'ok'},
            },
            {'type': 'diff', 'path': 'a.txt', 'oldText': 'x', 'newText': 'y'},
          ],
        }),
      );
    final tool = t.messages.single as ToolEvent;
    expect(tool.title, 'Run tests');
    expect(tool.kind, ToolKind.execute);
    expect(tool.status, ToolEventStatus.completed);
    expect(tool.content, hasLength(2));
    expect(tool.rawInput, {'command': 'npm test'});
  });

  test('a plan replaces the previous plan of the same turn', () {
    Map<String, dynamic> plan(String status) => {
      'sessionUpdate': 'plan',
      'entries': [
        {'content': 'Step', 'priority': 'high', 'status': status},
      ],
    };
    final t = Transcript()
      ..apply(u(plan('pending')))
      ..apply(u(chunk('agent_message_chunk', 'Working')))
      ..apply(u(plan('completed')));
    final plans = t.messages.whereType<PlanMsg>().toList();
    expect(plans, hasLength(1));
    expect(plans.single.entries.single.status, PlanStatus.completed);
  });

  test('notices and compactions show up; settings updates do not', () {
    final t = Transcript()
      ..apply(
        u({'sessionUpdate': 'notice', 'severity': 'error', 'title': 'Boom'}),
      )
      ..apply(
        u({
          'sessionUpdate': 'compaction_update',
          'compactionId': 'c',
          'status': 'in_progress',
        }),
      )
      ..apply(
        u({
          'sessionUpdate': 'compaction_summary_chunk',
          'compactionId': 'c',
          'content': {'type': 'text', 'text': 'Summary'},
        }),
      )
      ..apply(
        u({
          'sessionUpdate': 'compaction_update',
          'compactionId': 'c',
          'status': 'completed',
        }),
      )
      ..apply(u({'sessionUpdate': 'usage_update', 'used': 1, 'size': 2}))
      ..apply(u({'sessionUpdate': 'something_new'}));
    expect(t.messages, hasLength(2));
    expect((t.messages[0] as NoticeMsg).severity, 'error');
    final compaction = t.messages[1] as CompactionMsg;
    expect(compaction.summary, 'Summary');
    expect(compaction.done, isTrue);
  });

  test('awaiting marks only the tool a question waits on', () {
    final t = Transcript()
      ..apply(
        u({'sessionUpdate': 'tool_call', 'toolCallId': 'a', 'title': 'A'}),
      )
      ..apply(
        u({'sessionUpdate': 'tool_call', 'toolCallId': 'b', 'title': 'B'}),
      )
      ..markAwaiting({'b'});
    final tools = t.messages.cast<ToolEvent>();
    expect(tools.map((tool) => tool.awaitingApproval), [false, true]);
  });
}
