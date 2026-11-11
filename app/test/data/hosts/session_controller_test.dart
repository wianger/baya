import 'package:app/acp/acp.dart';
import 'package:app/acp/json_rpc.dart';
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

  group('coming back after a drop', () {
    Json chunk(String text, {int? seq, String role = 'agent'}) => {
      'sessionId': 's1',
      'update': {
        'sessionUpdate': '${role}_message_chunk',
        'content': {'type': 'text', 'text': text},
        if (role == 'user') 'messageId': 'm-$text',
      },
      if (seq != null)
        '_meta': {
          'baya': {'seq': seq},
        },
    };
    Json loaded({required int seq, bool resumed = false}) => {
      '_meta': {
        'baya': {
          'cursor': {'epoch': 'e1', 'seq': seq},
          'resumed': resumed,
        },
      },
    };

    Future<(FakeHost, HostConnection, SessionController)> opened() async {
      final (host, conn) = await online(FakeHost(sessions: [testSession()]));
      host.handlers['session/load'] = (_) {
        host.push('session/update', chunk('Hi', role: 'user'));
        host.push('session/update', chunk('Hello'));
        return loaded(seq: 4);
      };
      final session = SessionController(conn, 's1');
      await settle();
      host.push('session/update', chunk(' there', seq: 5));
      await settle();
      host.socket!.drop();
      await settle();
      return (host, conn, session);
    }

    String texts(SessionController session) => session.messages
        .map(
          (m) => switch (m) {
            UserMsg(:final text) => 'user:$text',
            AssistantMsg(:final text) => 'agent:$text',
            _ => '?',
          },
        )
        .join(' | ');

    test('it asks for what it missed and keeps what it has', () async {
      final (host, conn, session) = await opened();
      host.handlers['session/load'] = (params) {
        expect(bayaMeta(params)['resume'], {'epoch': 'e1', 'seq': 5});
        host.push('session/update', chunk('!', seq: 6));
        return loaded(seq: 6, resumed: true);
      };
      conn.reconnectNow();
      await settle();
      expect(texts(session), 'user:Hi | agent:Hello there!');
      expect(session.loading, isFalse);

      // The next drop resumes from the newest number seen.
      host.socket!.drop();
      await settle();
      host.handlers['session/load'] = (params) {
        expect(bayaMeta(params)['resume'], {'epoch': 'e1', 'seq': 6});
        return loaded(seq: 6, resumed: true);
      };
      conn.reconnectNow();
      await settle();
      expect(texts(session), 'user:Hi | agent:Hello there!');
      session.dispose();
      conn.dispose();
    });

    test(
      'a computer that cannot catch it up sends the history instead',
      () async {
        final (host, conn, session) = await opened();
        host.handlers['session/load'] = (_) {
          host.push('session/update', chunk('Hi', role: 'user'));
          host.push('session/update', chunk('Hello there, again'));
          return {
            '_meta': {
              'baya': {
                'cursor': {'epoch': 'e2', 'seq': 0},
                'resumed': false,
              },
            },
          };
        };
        conn.reconnectNow();
        await settle();
        expect(texts(session), 'user:Hi | agent:Hello there, again');
        session.dispose();
        conn.dispose();
      },
    );
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

  test('terminal output shows on the tool call that runs it', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    final session = SessionController(conn, 's1');
    await settle();
    host.update('s1', {
      'sessionUpdate': 'tool_call',
      'toolCallId': 't1',
      'title': 'npm test',
      'kind': 'execute',
      'content': [
        {'type': 'terminal', 'terminalId': 'term-1'},
      ],
    });
    host.push('_baya/terminal', {
      'sessionId': 's1',
      'terminalId': 'term-1',
      'output': 'ok 12 tests',
      'truncated': false,
      'exitStatus': {'exitCode': 0, 'signal': null},
    });
    await settle();
    final tool = session.messages.single as ToolEvent;
    expect(tool.terminal?.output, 'ok 12 tests');
    expect(tool.terminal?.exitCode, 0);
    session.dispose();
    conn.dispose();
  });

  test('an elicitation form is shown and answered', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    final session = SessionController(conn, 's1');
    await settle();
    final answer = host.askElicitation({
      'sessionId': 's1',
      'mode': 'form',
      'message': 'Deploy where?',
      'requestedSchema': {
        'type': 'object',
        'properties': {
          'target': {
            'type': 'string',
            'title': 'Target',
            'oneOf': [
              {'const': 'staging', 'title': 'Staging'},
              {'const': 'prod', 'title': 'Production'},
            ],
          },
          'dryRun': {'type': 'boolean', 'title': 'Dry run', 'default': true},
        },
        'required': ['target'],
      },
    });
    await settle();
    final form = session.elicitation!;
    expect(form.message, 'Deploy where?');
    expect(form.fields.map((f) => f.type), [
      ElicitationFieldType.choice,
      ElicitationFieldType.boolean,
    ]);
    expect(form.fields.first.options.last, ('prod', 'Production'));
    session.answerElicitation('accept', {'target': 'staging', 'dryRun': true});
    expect(await answer, {
      'action': 'accept',
      'content': {'target': 'staging', 'dryRun': true},
    });
    await settle();
    expect(session.elicitation, isNull);
    session.dispose();
    conn.dispose();
  });

  test('a turn that needs a sign-in names the agent', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    host.handlers['session/prompt'] = (_) => throw const RpcError(
      -32000,
      'Authentication required',
      {'reason': 'auth_required', 'agent': 'claude'},
    );
    final session = SessionController(conn, 's1');
    await settle();
    await session.prompt('Hi');
    expect(session.authAgent, 'claude');
    session.dispose();
    conn.dispose();
  });

  test('a burst of streamed chunks makes one rebuild, not one each', () async {
    final (host, conn) = await online(FakeHost(sessions: [testSession()]));
    final session = SessionController(conn, 's1');
    await settle();
    var notified = 0;
    session.addListener(() => notified++);
    for (var i = 0; i < 200; i++) {
      host.update('s1', {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'x'},
      });
    }
    await settle();
    expect(session.messages.whereType<AssistantMsg>().single.text, 'x' * 200);
    // The burst still reaches the screen, in at most a couple of rebuilds.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(notified, inInclusiveRange(1, 3));
    session.dispose();
    conn.dispose();
  });
}
