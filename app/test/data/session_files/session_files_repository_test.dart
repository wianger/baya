import 'package:app/data/session_files/session_files_repository.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/routing/adaptive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

void main() {
  test('browses and reads files of the selected session', () async {
    final host = FakeHost(sessions: [testSession()]);
    host.handlers['_baya/files'] = (params) => {
      'root': '/code/app',
      'path': '/code/app',
      'parent': null,
      'entries': [
        {
          'name': 'lib',
          'path': '/code/app/lib',
          'type': 'directory',
          'size': null,
          'modifiedAt': 1,
        },
        {
          'name': 'a.md',
          'path': '/code/app/a.md',
          'type': 'file',
          'size': 3,
          'modifiedAt': 2,
        },
      ],
      'truncated': false,
    };
    host.handlers['_baya/read_file'] = (params) => {
      'name': 'a.md',
      'path': params['path'],
      'size': 3,
      'modifiedAt': 2,
      'content': 'hi\n',
      'binary': false,
      'truncated': false,
    };
    final hosts = testHosts(MemoryStorage([testPeer()]), host);
    await hosts.start();
    await settle();
    final selection = SessionSelection()
      ..select(testPeer().remoteEpk, 's1', 'app');
    final repo = SessionFilesRepository(hosts, selection);

    final listing = await repo.browse();
    expect(listing.entries.map((e) => e.kind), [
      SessionFileKind.directory,
      SessionFileKind.file,
    ]);
    expect(host.calls.last.params['sessionId'], 's1');
    final file = await repo.read('/code/app/a.md');
    expect(file.content, 'hi\n');
    hosts.dispose();
  });

  test('nothing selected means offline', () async {
    final hosts = testHosts(MemoryStorage(), FakeHost());
    final repo = SessionFilesRepository(hosts, SessionSelection());
    await expectLater(repo.browse(), throwsA(isA<SessionFilesFailure>()));
  });
}
