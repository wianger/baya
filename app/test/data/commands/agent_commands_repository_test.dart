import 'package:app/data/commands/agent_commands_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/agent_commands_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/phone_controls.dart';

void main() {
  const daemon = 'pi_abcdefghijklmnop_d_ABCDEFGHIJKL';
  const terminal = 'pi_abcdefghijklmnop_i_MNOPQRSTUVWX';
  const other = 'pi_QRSTUVWXYZ012345_i_ABCDEFGHIJKL';

  test(
    'correlates command replies and accepts equivalent Pi endpoints',
    () async {
      final peer = phoneTestPeer(room: daemon);
      final channel = PhoneTestChannel();
      final conn = ConnectionManager(
        storage: PhoneTestStorage([peer]),
        factory: (_, _) async => channel,
      );
      conn.adopt(channel, peer);
      final repository = AgentCommandsRepository(conn);
      channel.onSend = (message) {
        if (message is! GetCommands) return;
        channel.messages.add(
          CommandsList(
            inReplyTo: 'not-this-request',
            commands: const [WireAgentCommand(name: 'wrong', source: 'skill')],
          ),
        );
        conn.switchRoom(terminal);
        channel.messages.add(
          ServerMessage.fromJson({
            'type': 'commands_list',
            'in_reply_to': message.id,
            'commands': [
              {
                'name': 'review',
                'source': 'extension',
                'description': 'Review a change',
              },
              {
                'name': 'browser',
                'source': 'skill',
                'description': 'Drive a browser',
              },
            ],
          }),
        );
      };

      final commands = await repository.list();

      expect(commands.map((command) => command.name), ['review', 'browser']);
      expect(commands.last.source, 'skill');
      expect(channel.sent.whereType<GetCommands>(), hasLength(1));
      conn.dispose();
      await channel.disposeStreams();
    },
  );

  test('rejects a reply after switching to another conversation', () async {
    final peer = phoneTestPeer(room: daemon);
    final channel = PhoneTestChannel();
    final conn = ConnectionManager(
      storage: PhoneTestStorage([peer]),
      factory: (_, _) async => channel,
    );
    conn.adopt(channel, peer);
    final repository = AgentCommandsRepository(conn);
    channel.onSend = (message) {
      if (message is! GetCommands) return;
      conn.switchRoom(other);
      channel.messages.add(
        CommandsList(
          inReplyTo: message.id,
          commands: const [
            WireAgentCommand(name: 'stale', source: 'extension'),
          ],
        ),
      );
    };

    await expectLater(repository.list(), throwsA(isA<AgentCommandsFailure>()));
    conn.dispose();
    await channel.disposeStreams();
  });
}
