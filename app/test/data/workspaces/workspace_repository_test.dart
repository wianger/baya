import 'dart:convert';

import 'package:app/data/workspaces/workspace_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

void main() {
  test('lists computers, browses folders and starts a session', () async {
    final host = FakeHost();
    final storage = MemoryStorage([testPeer()]);
    final hosts = testHosts(storage, host);
    await hosts.start();
    await settle();
    final repo = WorkspaceRepository(hosts);

    final computers = await repo.listHosts();
    expect(computers.single.online, isTrue);
    expect(computers.single.label, 'PC');

    final folder = await repo.browse(computers.single.id, path: '/home/me');
    expect(folder.folders.single.name, 'code');
    expect(folder.availableAgents.single.label, 'Claude Code');

    final opened = await repo.open(
      computers.single.id,
      '/home/me/code',
      folder.availableAgents.single,
    );
    expect(opened.sessionId, 'new-1');
    final created = host.calls.lastWhere((c) => c.method == 'session/new');
    expect(created.params['cwd'], '/home/me/code');
    expect(created.params['_meta'], {
      'baya': {'agent': 'claude'},
    });
    hosts.dispose();
  });

  test('an offline computer is refused with a reason', () async {
    final host = FakeHost()..refuse = Exception('offline');
    final storage = MemoryStorage([testPeer()]);
    final hosts = testHosts(storage, host);
    await hosts.start();
    await settle();
    final repo = WorkspaceRepository(hosts);
    await expectLater(
      repo.browse(testPeer().remoteEpk),
      throwsA(isA<WorkspaceFailure>()),
    );
    hosts.dispose();
  });

  test('computers are identified by the key workspaces use', () async {
    // Pairing stores the QR's base64url key; workspaces use standard base64.
    final bytes = List.filled(32, 0xfb);
    final peer = testPeer();
    final paired = PeerRecord(
      remoteEpk: base64Url.encode(bytes).replaceAll('=', ''),
      name: peer.name,
      endpoint: peer.endpoint,
      pairedAt: peer.pairedAt,
    );
    final hosts = testHosts(MemoryStorage([paired]), FakeHost());
    await hosts.start();
    await settle();
    final computers = await WorkspaceRepository(hosts).listHosts();
    expect(computers.single.id, base64.encode(bytes));
    hosts.dispose();
  });
}
