import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/data/launcher/launcher.dart';
import 'package:app/domain/session_state.dart';
import 'package:cryptography/cryptography.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/acp_harness.dart';

class _Launcher implements Launcher {
  final sets = <List<SessionShortcut>>[];

  @override
  Stream<String> get shared => const Stream.empty();

  @override
  Future<String?> takeLaunchText() async => null;

  @override
  Future<void> setShortcuts(List<SessionShortcut> sessions) async =>
      sets.add(sessions);
}

void main() {
  test('shared text goes to the composer of the next session opened', () async {
    final host = FakeHost(
      sessions: [
        testSession(),
        testSession(id: 's2'),
      ],
    );
    final conn = HostConnection(
      host: testPeer(),
      connect: host.connect,
      identity: () => Ed25519().newKeyPair(),
    );
    await conn.start();
    await settle();
    final shared = SharedDraft()..offer('TypeError: x is undefined');

    final first = SessionController(conn, 's1', shared: shared);
    final drafts = <UserMsg>[];
    final sub = first.drafts.listen(drafts.add);
    await settle();
    expect(drafts.map((m) => m.text), ['TypeError: x is undefined']);
    expect(shared.text, isNull);

    // Taken once: the next session opens with an empty composer.
    final second = SessionController(conn, 's2', shared: shared);
    final more = <UserMsg>[];
    final sub2 = second.drafts.listen(more.add);
    await settle();
    expect(more, isEmpty);

    await sub.cancel();
    await sub2.cancel();
    first.dispose();
    second.dispose();
    conn.dispose();
  });

  test('the launcher shortcuts follow the sessions used last', () {
    fakeAsync((async) {
      final host = FakeHost(
        sessions: [
          for (var i = 0; i < 6; i++)
            testSession(
              id: 's$i',
              title: 'Task $i',
              updatedAt: DateTime.utc(2026, 11, 1 + i),
            ),
        ],
      );
      final hosts = testHosts(MemoryStorage([testPeer(name: 'studio')]), host);
      final launcher = _Launcher();
      final shortcuts = SessionShortcuts(hosts, launcher)..start();
      hosts.start();
      async.elapse(const Duration(seconds: 3));
      expect(
        [for (final s in launcher.sets.last) s.title],
        ['Task 5', 'Task 4', 'Task 3', 'Task 2'],
      );
      expect(launcher.sets.last.first.subtitle, 'studio');

      // Settled: one set, not one per change while connecting.
      async.elapse(const Duration(seconds: 3));
      expect(launcher.sets, hasLength(1));

      shortcuts.dispose();
      hosts.dispose();
    });
  });
}
