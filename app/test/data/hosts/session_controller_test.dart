import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/domain/session_state.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

Future<(FakeHost, HostConnection)> online(FakeHost host) async {
  final conn = HostConnection(
    host: testPeer(),
    connect: host.connect,
    identity: () => Ed25519().newKeyPair(),
  );
  await conn.start();
  await settle();
  return (host, conn);
}

void main() {
  test('opening replays the history and applies the setup', () async {
    final host = FakeHost(sessions: [testSession()])
      ..history['s1'] = [
        {
          'sessionUpdate': 'user_message_chunk',
          'content': {'type': 'text', 'text': 'Hi'},
          'messageId': 'm0',
        },
        {
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': 'Hello'},
        },
        {
          'sessionUpdate': 'available_commands_update',
          'availableCommands': [
            {'name': 'compact', 'description': 'Compact'},
          ],
        },
        {'sessionUpdate': 'usage_update', 'used': 50, 'size': 100},
      ]
      ..setup = {
        'configOptions': [
          {
            'id': 'model',
            'name': 'Model',
            'category': 'model',
            'type': 'select',
            'currentValue': 'opus',
            'options': [
              {'value': 'opus', 'name': 'Opus'},
              {'value': 'sonnet', 'name': 'Sonnet'},
            ],
          },
        ],
        '_meta': {
          'baya': {
            'agentName': 'Claude Code',
            'promptCapabilities': {'image': true},
          },
        },
      };
    final (_, conn) = await online(host);
    final session = SessionController(conn, 's1');
    await settle();
    expect(session.loaded, isTrue);
    expect(session.messages.map((m) => m.runtimeType), [UserMsg, AssistantMsg]);
    expect(session.configFor('model')?.current?.name, 'Opus');
    expect(session.commands.single.name, 'compact');
    expect(session.usage?.fraction, 0.5);
    expect(session.acceptsImages, isTrue);
    expect(session.agentName, 'Claude Code');
    session.dispose();
    await settle();
    expect(host.calls.last.method, 'session/close');
    conn.dispose();
  });

  test('a prompt shows at once, then the echo and the reply', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    final session = SessionController(conn, 's1');
    await settle();
    final sent = session.prompt('Fix the bug');
    expect((session.messages.single as UserMsg).status, UserMsgStatus.pending);
    expect(session.working, isTrue);
    await sent;
    await settle();
    final rows = session.messages;
    expect((rows.first as UserMsg).status, UserMsgStatus.confirmed);
    expect((rows.last as AssistantMsg).text, 'Done.');
    expect(session.working, isFalse);
    final prompt = host.calls.lastWhere((c) => c.method == 'session/prompt');
    expect(prompt.params['prompt'], [
      {'type': 'text', 'text': 'Fix the bug'},
    ]);
    session.dispose();
    conn.dispose();
  });

  test('a turn that fails on the computer shows its notice once', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    host.handlers['session/prompt'] = (params) {
      host.update('s1', {
        'sessionUpdate': 'notice',
        'severity': 'error',
        'title': 'Agent crashed',
      });
      throw Exception('Agent crashed');
    };
    final session = SessionController(conn, 's1');
    await settle();
    await session.prompt('Hi');
    await settle();
    expect(
      session.messages.whereType<NoticeMsg>().single.text,
      'Agent crashed',
    );
    expect(session.messages.whereType<UserMsg>(), isEmpty);
    session.dispose();
    conn.dispose();
  });

  test('a send lost with the connection leaves a notice', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    host.handlers['session/prompt'] = (_) async {
      host.socket!.drop();
      return const <String, dynamic>{};
    };
    final session = SessionController(conn, 's1');
    await settle();
    await session.prompt('Hi');
    expect(session.messages.single, isA<NoticeMsg>());
    session.dispose();
    conn.dispose();
  });

  test('cancel is a notification for this session', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    final session = SessionController(conn, 's1');
    await settle();
    session.cancel();
    await settle();
    final note = host.socket!.notifications.single;
    expect(note.method, 'session/cancel');
    expect(note.params, {'sessionId': 's1'});
    session.dispose();
    conn.dispose();
  });

  test('its permission question is shown and answered', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    final session = SessionController(conn, 's1');
    await settle();
    host.update('s1', {
      'sessionUpdate': 'tool_call',
      'toolCallId': 't1',
      'title': 'Edit',
    });
    final answer = host.askPermission({
      'sessionId': 's1',
      'toolCall': {'toolCallId': 't1'},
      'options': [
        {'optionId': 'ok', 'name': 'Allow', 'kind': 'allow_once'},
      ],
    });
    await settle();
    expect(session.permission?.toolCall.id, 't1');
    expect((session.messages.single as ToolEvent).awaitingApproval, isTrue);
    session.answerPermission('ok');
    expect(await answer, {
      'outcome': {'outcome': 'selected', 'optionId': 'ok'},
    });
    await settle();
    expect(session.permission, isNull);
    expect((session.messages.single as ToolEvent).awaitingApproval, isFalse);
    session.dispose();
    conn.dispose();
  });

  test('another session\'s updates are ignored', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    final session = SessionController(conn, 's1');
    await settle();
    host.update('other', {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': 'not mine'},
    });
    await settle();
    expect(session.messages, isEmpty);
    session.dispose();
    conn.dispose();
  });

  test('working follows the computer, not only this phone', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    final session = SessionController(conn, 's1');
    await settle();
    host.push('_baya/session_changed', {
      'session': testSession(working: true).toJson(),
    });
    await settle();
    expect(session.working, isTrue);
    session.dispose();
    conn.dispose();
  });
}
