import 'dart:async';

import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/agent_commands_repository.dart';
import 'package:app/domain/entities/agent_command.dart';
import 'package:app/domain/value_objects/session_room.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

class AgentCommandsRepository implements IAgentCommandsRepository {
  AgentCommandsRepository(
    this._connection, {
    this.timeout = const Duration(seconds: 6),
  });

  final ConnectionManager _connection;
  final Duration timeout;

  @override
  void dispose() {}

  @override
  Future<List<AgentCommand>> list() async {
    final channel = _connection.channel;
    final peer = _connection.activePeer?.remoteEpk;
    final conversation = conversationRoomId(_connection.activeRoomId);
    if (channel == null || peer == null) {
      throw const AgentCommandsFailure(
        'Connect to this session to load agent slash commands.',
      );
    }
    final id = uuid7();
    final result = Completer<List<AgentCommand>>();
    final subscription = channel.serverMessages.listen(
      (message) {
        if (result.isCompleted) return;
        if (message is CommandsList && message.inReplyTo == id) {
          result.complete(
            message.commands
                .map(
                  (command) => AgentCommand(
                    name: command.name,
                    source: command.source,
                    description: command.description,
                  ),
                )
                .toList(growable: false),
          );
        } else if (message is ErrorMessage && message.inReplyTo == id) {
          result.completeError(AgentCommandsFailure(message.message));
        }
      },
      onDone: () {
        if (!result.isCompleted) {
          result.completeError(
            const AgentCommandsFailure('The computer disconnected.'),
          );
        }
      },
      onError: (Object _, StackTrace _) {
        if (!result.isCompleted) {
          result.completeError(
            const AgentCommandsFailure('The computer disconnected.'),
          );
        }
      },
    );
    final reply = result.future.timeout(
      timeout,
      onTimeout: () => throw const AgentCommandsFailure(
        'The computer did not return its slash commands. Retry after reconnecting.',
      ),
    );
    try {
      final values = await Future.wait<dynamic>([
        reply,
        Future<void>.sync(() => channel.send(GetCommands(id: id))),
      ], eagerError: true);
      if (_connection.activePeer?.remoteEpk != peer ||
          conversationRoomId(_connection.activeRoomId) != conversation) {
        throw const AgentCommandsFailure('The selected session changed.');
      }
      return values.first as List<AgentCommand>;
    } on AgentCommandsFailure {
      rethrow;
    } catch (_) {
      throw const AgentCommandsFailure(
        'Could not load slash commands from this session.',
      );
    } finally {
      if (!result.isCompleted) {
        result.completeError(
          const AgentCommandsFailure('Slash command request cancelled.'),
        );
      }
      await subscription.cancel();
    }
  }
}
