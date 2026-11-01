import 'package:app/data/context/context_usage_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/context_usage_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/phone_controls.dart';

void main() {
  const daemon = 'pi_abcdefghijklmnop_d_ABCDEFGHIJKL';
  const terminal = 'pi_abcdefghijklmnop_i_MNOPQRSTUVWX';

  test(
    'accepts the interactive endpoint for the same Pi conversation',
    () async {
      final peer = phoneTestPeer(room: daemon);
      final channel = PhoneTestChannel();
      final conn = ConnectionManager(
        storage: PhoneTestStorage([peer]),
        factory: (_, _) async => channel,
      );
      conn.adopt(channel, peer);
      channel.onSend = (message) {
        if (message is! GetContextUsage) return;
        conn.switchRoom(terminal);
        channel.messages.add(
          ContextUsageReply(inReplyTo: message.id, tokens: 55, window: 100),
        );
      };

      final usage = await ContextUsageRepository(conn).fetch();

      expect(usage.percent, 55);
      conn.dispose();
      await channel.disposeStreams();
    },
  );

  test(
    'query correlates replies and rejects a reply for a room that is no longer selected',
    () async {
      final peer = phoneTestPeer(), channel = PhoneTestChannel();
      final conn = ConnectionManager(
        storage: PhoneTestStorage([peer]),
        factory: (_, _) async => channel,
      );
      conn.adopt(channel, peer);
      final repo = ContextUsageRepository(conn);
      channel.onSend = (message) {
        if (message is GetContextUsage) {
          channel.messages.add(
            ContextUsageReply(inReplyTo: 'wrong-id', tokens: 99, window: 100),
          );
          channel.messages.add(
            ServerMessage.fromJson({
              'type': 'context_usage',
              'in_reply_to': message.id,
              'tokens': 40_000,
              'context_window': 100_000,
              'source': 'pi',
            }),
          );
        }
      };
      final usage = await repo.fetch();
      expect(usage.tokens, 40_000);
      expect(usage.percent, 40);
      channel.onSend = (message) {
        if (message is GetContextUsage) {
          conn.switchRoom('another-room');
          channel.messages.add(
            ContextUsageReply(inReplyTo: message.id, tokens: 1, window: 100),
          );
        }
      };
      await expectLater(repo.fetch(), throwsA(isA<ContextUsageFailure>()));
      conn.dispose();
      await channel.disposeStreams();
    },
  );
  test(
    'offline usage is an error and unknown reported usage is not zero',
    () async {
      final channel = PhoneTestChannel();
      final conn = ConnectionManager(
        storage: PhoneTestStorage([]),
        factory: (_, _) async => channel,
      );
      await expectLater(
        ContextUsageRepository(conn).fetch(),
        throwsA(isA<ContextUsageFailure>()),
      );
      final reply =
          ServerMessage.fromJson({
                'type': 'context_usage',
                'in_reply_to': 'x',
                'tokens': null,
                'context_window': 200_000,
                'source': 'pi',
              })
              as ContextUsageReply;
      expect(reply.tokens, isNull);
      expect(reply.window, 200_000);
      conn.dispose();
      await channel.disposeStreams();
    },
  );
}
