import 'dart:async';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/context_usage_repository.dart';
import 'package:app/domain/entities/context_usage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

class ContextUsageRepository implements IContextUsageRepository {
  ContextUsageRepository(
    this._connection, {
    this.timeout = const Duration(seconds: 8),
  });
  final ConnectionManager _connection;
  final Duration timeout;
  @override
  Future<ContextUsageSnapshot> fetch() async {
    final channel = _connection.channel;
    final peer = _connection.activePeer?.remoteEpk;
    final conversation = _connection.activeRoomId;
    if (channel == null || peer == null) {
      throw const ContextUsageFailure(
        'Connect to this session to view context usage.',
      );
    }
    final id = uuid7(), result = Completer<ContextUsageSnapshot>();
    final sub = channel.serverMessages.listen(
      (message) {
        if (result.isCompleted) return;
        if (message is ContextUsageReply && message.inReplyTo == id) {
          result.complete(
            ContextUsageSnapshot(
              tokens: message.tokens,
              window: message.window,
              source: message.source,
            ),
          );
        } else if (message is ErrorMessage && message.inReplyTo == id) {
          result.completeError(ContextUsageFailure(message.message));
        }
      },
      onDone: () {
        if (!result.isCompleted) {
          result.completeError(
            const ContextUsageFailure('The computer disconnected.'),
          );
        }
      },
      onError: (Object _, StackTrace _) {
        if (!result.isCompleted) {
          result.completeError(
            const ContextUsageFailure('The computer disconnected.'),
          );
        }
      },
    );
    final reply = result.future.timeout(
      timeout,
      onTimeout: () => throw const ContextUsageFailure(
        'The computer did not report context usage. Update Baya on the computer and try again.',
      ),
    );
    try {
      final results = await Future.wait<dynamic>([
        reply,
        Future<void>.sync(() => channel.send(GetContextUsage(id: id))),
      ], eagerError: true);
      if (_connection.activePeer?.remoteEpk != peer ||
          _connection.activeRoomId != conversation) {
        throw const ContextUsageFailure(
          'The selected session changed. Refresh to view its context.',
        );
      }
      return results.first as ContextUsageSnapshot;
    } on ContextUsageFailure {
      rethrow;
    } catch (_) {
      throw const ContextUsageFailure(
        'Could not read context usage. Check the connection and try again.',
      );
    } finally {
      if (!result.isCompleted) {
        result.completeError(
          const ContextUsageFailure("Context request cancelled."),
        );
      }
      await sub.cancel();
    }
  }
}
