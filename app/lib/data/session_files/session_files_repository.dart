import 'dart:async';

import 'package:app/domain/contracts/repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

class SessionFilesRepository extends Repository
    implements ISessionFilesRepository {
  SessionFilesRepository(
    this._connection, {
    this.timeout = const Duration(seconds: 25),
  });

  final ConnectionManager _connection;
  final Duration timeout;

  Future<Map<String, dynamic>?> _request(
    ClientMessage Function(String) makeMessage,
  ) async {
    final channel = _connection.channel;
    if (channel == null || _connection.activePeer == null) {
      throw const SessionFilesFailure(
        'This session is offline. Reconnect to the computer and try again.',
      );
    }
    final id = uuid7();
    final completer = Completer<Map<String, dynamic>?>();
    late final StreamSubscription<ServerMessage> subscription;
    subscription = channel.serverMessages.listen(
      (message) {
        switch (message) {
          case SessionFilesListing(:final inReplyTo, :final directory)
              when inReplyTo == id:
            if (!completer.isCompleted) {
              completer.complete({'type': 'directory', 'value': directory});
            }
          case SessionFileContentReply(:final inReplyTo, :final file)
              when inReplyTo == id:
            if (!completer.isCompleted) {
              completer.complete({'type': 'file', 'value': file});
            }
          case SessionFileError(:final inReplyTo, :final error)
              when inReplyTo == id:
            if (!completer.isCompleted) {
              completer.completeError(SessionFilesFailure(error));
            }
          case ErrorMessage(:final inReplyTo, :final message)
              when inReplyTo == id:
            if (!completer.isCompleted) {
              completer.completeError(SessionFilesFailure(message));
            }
          default:
            break;
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            const SessionFilesFailure('The computer disconnected.'),
          );
        }
      },
      onError: (Object _, StackTrace _) {
        if (!completer.isCompleted) {
          completer.completeError(
            const SessionFilesFailure('The computer disconnected.'),
          );
        }
      },
    );
    final reply = completer.future.timeout(
      timeout,
      onTimeout: () {
        throw const SessionFilesFailure(
          'The computer did not respond. Update Baya on the computer and reconnect.',
        );
      },
    );
    try {
      final results = await Future.wait<Object?>([
        reply,
        channel.send(makeMessage(id)),
      ], eagerError: true);
      return results.first as Map<String, dynamic>?;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<SessionDirectoryListing> browse({
    String? path,
    bool showHidden = false,
  }) async {
    try {
      final result = await _request(
        (id) => SessionFilesBrowse(id: id, path: path, showHidden: showHidden),
      );
      if (result?['type'] != 'directory') {
        throw const SessionFilesFailure('Unexpected directory response.');
      }
      final data = Map<String, dynamic>.from(result!['value'] as Map);
      final entries = (data['entries'] as List)
          .map((raw) {
            final entry = Map<String, dynamic>.from(raw as Map);
            return SessionFileEntry(
              name: entry['name'] as String,
              path: entry['path'] as String,
              kind: switch (entry['type']) {
                'directory' => SessionFileKind.directory,
                _ => SessionFileKind.file,
              },
              size: (entry['size'] as num?)?.toInt(),
              modifiedAt: _timestamp(entry['modified_at']),
            );
          })
          .toList(growable: false);
      return SessionDirectoryListing(
        root: data['root'] as String,
        path: data['path'] as String,
        parent: data['parent'] as String?,
        entries: entries,
        truncated: data['truncated'] == true,
      );
    } on SessionFilesFailure {
      rethrow;
    } catch (_) {
      throw const SessionFilesFailure(
        'Could not read files in this session directory.',
      );
    }
  }

  @override
  Future<SessionFileContent> read(String path) async {
    try {
      final result = await _request(
        (id) => SessionFileRead(id: id, path: path),
      );
      if (result?['type'] != 'file') {
        throw const SessionFilesFailure('Unexpected file response.');
      }
      final data = Map<String, dynamic>.from(result!['value'] as Map);
      return SessionFileContent(
        name: data['name'] as String,
        path: data['path'] as String,
        size: (data['size'] as num).toInt(),
        modifiedAt: _timestamp(data['modified_at']),
        content: data['content'] as String?,
        binary: data['binary'] == true,
        truncated: data['truncated'] == true,
      );
    } on SessionFilesFailure {
      rethrow;
    } catch (_) {
      throw const SessionFilesFailure('Could not read this file.');
    }
  }

  DateTime? _timestamp(Object? raw) {
    final milliseconds = (raw as num?)?.toInt();
    return milliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
}
