// HomeList.items() flattens computers × sessions into rows.

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

void main() {
  group('HomeList.items()', () {
    test('a computer without sessions produces no rows', () {
      final list = HomeList(peers: [testPeer()]);
      expect(list.items(normalizeEpk: toStandardB64), isEmpty);
    });

    test('one row per session, computers sorted by label', () {
      final a = testPeer(seed: 1, name: 'Beta');
      final b = testPeer(seed: 2, name: 'Alpha');
      final list = HomeList(
        peers: [a, b],
        sessionsByPeer: {
          a.remoteEpk: [testSession(id: 'a1')],
          b.remoteEpk: [testSession(id: 'b1'), testSession(id: 'b2')],
        },
      );
      final items = list.items(normalizeEpk: toStandardB64);
      expect(items.map((i) => i.sessionId), ['b1', 'b2', 'a1']);
    });

    test('equivalent key encodings find the same sessions', () {
      const urlSafe = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
      const standard = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
      final peer = const PeerRecord(
        remoteEpk: urlSafe,
        name: 'PC',
        endpoint: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      final list = HomeList(
        peers: [peer],
        sessionsByPeer: {
          standard: [testSession(id: 'r1')],
        },
      );
      expect(list.items(normalizeEpk: toStandardB64).single.sessionId, 'r1');
    });

    test('the display name is the session title', () {
      final list = HomeList(
        peers: [testPeer()],
        sessionsByPeer: {
          testPeer().remoteEpk: [testSession(title: 'Fix the login bug')],
        },
      );
      expect(
        list.items(normalizeEpk: toStandardB64).single.displayName,
        'Fix the login bug',
      );
    });
  });
}
