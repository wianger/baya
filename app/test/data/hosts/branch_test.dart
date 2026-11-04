import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/domain/session_state.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

const _sha256OfOk =
    'sha256:565339bc4d33d72817b583024112eb7f5cdf3e5eef0252d6ec1b9c9a94e12bb3';

void main() {
  test('a branch ends at the reply before the message, by id and text', () {
    const messages = <ChatMessage>[
      UserMsg(id: 'u1', text: 'one'),
      AssistantMsg(id: 'msg_a', text: 'OK'),
      UserMsg(id: 'u2', text: 'two'),
      AssistantMsg(id: 'msg_b', text: 'OK'),
      UserMsg(id: 'u3', text: 'three'),
    ];
    expect(SessionController.forkPoint(messages, messages[4] as UserMsg), {
      'messageId': 'msg_b',
      'messageFingerprint': _sha256OfOk,
      'messageOccurrence': 2,
    });
    expect(
      (SessionController.forkPoint(
        messages,
        messages[2] as UserMsg,
      ))!['messageId'],
      'msg_a',
    );
    // Before the first reply there is nothing to keep.
    expect(
      SessionController.forkPoint(messages, messages[0] as UserMsg),
      isNull,
    );
  });

  test('the branch opens with the message waiting in its composer', () async {
    final host = FakeHost(sessions: [testSession(title: 'Fix login')])
      ..history['s1'] = [
        {
          'sessionUpdate': 'user_message_chunk',
          'content': {'type': 'text', 'text': 'Why does login fail?'},
          'messageId': 'u1',
        },
        {
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': 'The token expired.'},
          'messageId': 'msg_a',
        },
        {
          'sessionUpdate': 'user_message_chunk',
          'content': {'type': 'text', 'text': 'Fix it'},
          'messageId': 'u2',
        },
      ]
      ..setup = {
        '_meta': {
          'baya': {'agentName': 'Claude Code', 'canFork': true},
        },
      };
    host.handlers['_baya/fork'] = (params) => {
      'session': {'sessionId': 'branch'},
    };
    final conn = HostConnection(
      host: testPeer(),
      connect: host.connect,
      identity: () => Ed25519().newKeyPair(),
    );
    await conn.start();
    await settle();
    final source = SessionController(conn, 's1');
    await settle();
    expect(source.canFork, isTrue);

    final fix = source.messages.whereType<UserMsg>().last;
    expect(await source.branchBefore(fix), 'branch');
    final fork = host.calls.lastWhere((c) => c.method == '_baya/fork');
    expect(fork.params['sessionId'], 's1');
    expect(fork.params['messageId'], 'msg_a');

    final branch = SessionController(conn, 'branch');
    final drafts = <UserMsg>[];
    final sub = branch.drafts.listen(drafts.add);
    await settle();
    expect(drafts.map((m) => m.text), ['Fix it']);

    await sub.cancel();
    branch.dispose();
    source.dispose();
    await settle();
    conn.dispose();
  });
}
