import 'package:app/acp/acp.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/transport/host_socket.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

HostConnection connection(FakeHost host, {MemoryStorage? cache}) =>
    HostConnection(
      host: testPeer(),
      connect: host.connect,
      identity: () => Ed25519().newKeyPair(),
      cache: cache,
    );

void main() {
  test('connects, introduces itself and lists the sessions', () async {
    final host = FakeHost(
      sessions: [
        testSession(id: 'a'),
        testSession(id: 'b'),
      ],
    );
    final storage = MemoryStorage();
    final conn = connection(host, cache: storage);
    await conn.start();
    await settle();
    expect(conn.status, HostStatus.online);
    expect(conn.intro?.hostname, 'studio');
    expect(conn.agents.single.name, 'Claude Code');
    expect(conn.sessions.map((s) => s.sessionId), containsAll(['a', 'b']));
    expect(host.calls.first.method, 'initialize');
    // The list is cached for the next cold start.
    expect(storage.sessions[conn.key], hasLength(2));
    conn.dispose();
  });

  test('pushes keep the session list current', () async {
    final host = FakeHost(sessions: [testSession(id: 'a')]);
    final conn = connection(host);
    await conn.start();
    await settle();
    host.push('_baya/session_changed', {
      'session': testSession(id: 'a', working: true).toJson(),
    });
    host.push('_baya/session_changed', {
      'session': testSession(id: 'c').toJson(),
    });
    await settle();
    expect(conn.session('a')?.working, isTrue);
    expect(conn.session('c'), isNotNull);
    host.push('_baya/session_removed', {'sessionId': 'a'});
    await settle();
    expect(conn.session('a'), isNull);
    conn.dispose();
  });

  test('shows cached sessions as not running before it connects', () async {
    final host = FakeHost()..refuse = Exception('offline');
    final storage = MemoryStorage();
    final conn = connection(host, cache: storage);
    storage.sessions[conn.key] = [testSession(id: 'old', working: true)];
    await conn.start();
    await settle();
    expect(conn.status, HostStatus.offline);
    expect(conn.sessions.single.working, isFalse);
    conn.dispose();
  });

  test('a computer that forgot this phone stops the retries', () async {
    final host = FakeHost()..unpaired = true;
    final conn = connection(host);
    await conn.start();
    await settle();
    expect(conn.status, HostStatus.unpaired);
    expect(conn.error, contains('re-pair'));
    conn.dispose();
  });

  test('closing with 4003 means unpaired; any other close retries', () async {
    final host = FakeHost();
    final conn = connection(host);
    await conn.start();
    await settle();
    host.socket!.drop(HostClose.noise, 'transport');
    await settle();
    expect(conn.status, HostStatus.offline);
    conn.reconnectNow();
    await settle();
    expect(conn.status, HostStatus.online);
    host.socket!.drop(HostClose.unpaired, 'unpaired');
    await settle();
    expect(conn.status, HostStatus.unpaired);
    conn.dispose();
  });

  test('calls fail fast while offline', () async {
    final host = FakeHost()..refuse = Exception('offline');
    final conn = connection(host);
    await conn.start();
    await settle();
    await expectLater(conn.call('session/list'), throwsA(anything));
    conn.dispose();
  });

  test('session updates are routed by session', () async {
    final host = FakeHost();
    final conn = connection(host);
    await conn.start();
    await settle();
    final events = <SessionEvent>[];
    conn.updates.listen(events.add);
    host.update('s1', {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': 'hi'},
    });
    await settle();
    expect(events.single.sessionId, 's1');
    expect(events.single.update, isA<MessageChunk>());
    conn.dispose();
  });
}
