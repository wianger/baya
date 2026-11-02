import 'dart:async';
import 'dart:convert';

import 'package:app/data/session_files/session_files_repository.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _Channel implements IChannel {
  final messages = StreamController<ServerMessage>.broadcast();
  final sent = <ClientMessage>[];

  @override
  Stream<ServerMessage> get serverMessages => messages.stream;

  @override
  Future<void> send(ClientMessage message) async {
    sent.add(message);
    switch (message) {
      case SessionFilesBrowse(:final id, :final path, :final showHidden):
        messages.add(
          SessionFilesListing(
            inReplyTo: id,
            directory: {
              'root': r'C:\project',
              'path': path ?? r'C:\project',
              'parent': null,
              'entries': [
                {
                  'name': 'lib',
                  'path': r'C:\project\lib',
                  'type': 'directory',
                  'size': null,
                  'modified_at': 1700000000000,
                },
                {
                  'name': showHidden ? '.env' : 'README.md',
                  'path': showHidden
                      ? r'C:\project\.env'
                      : r'C:\project\README.md',
                  'type': 'file',
                  'size': 42,
                  'modified_at': 1700000000000,
                },
              ],
              'truncated': false,
            },
          ),
        );
      case SessionFileRead(:final id, :final path):
        messages.add(
          SessionFileContentReply(
            inReplyTo: id,
            file: {
              'name': 'README.md',
              'path': path,
              'size': 42,
              'modified_at': 1700000000000,
              'content': '# Remote Pi',
              'binary': false,
              'truncated': false,
            },
          ),
        );
      default:
        break;
    }
  }

  @override
  Future<void> close() => messages.close();
}

class _Storage extends PairingStorage {}

void main() {
  test('browses and reads within the active session connection', () async {
    final channel = _Channel();
    final conn = ConnectionManager(
      storage: _Storage(),
      factory: (_, _) async => channel,
    );
    final peer = PeerRecord(
      remoteEpk: base64Encode(List.filled(32, 7)),
      sessionName: 'project',
      roomId: 'room',
      relayUrl: 'https://example.invalid',
      pairedAt: '2026-11-01',
    );
    conn.adopt(channel, peer);
    final repository = SessionFilesRepository(conn);

    final listing = await repository.browse(showHidden: true);
    expect(listing.root, r'C:\project');
    expect(listing.entries.last.name, '.env');
    expect(listing.entries.first.kind, SessionFileKind.directory);
    expect(
      (channel.sent.last as SessionFilesBrowse).toJson()['show_hidden'],
      isTrue,
    );

    final file = await repository.read(r'C:\project\README.md');
    expect(file.content, '# Remote Pi');
    expect(file.binary, isFalse);
    expect(file.modifiedAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));

    conn.dispose();
  });
}
