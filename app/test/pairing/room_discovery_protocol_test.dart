// Protocol additions for room discovery.

import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairOk — room_id', () {
    test('parses room_id from pair_ok payload', () {
      final j = {
        'type': 'pair_ok',
        'hostname': 'studio',
        'in_reply_to': 'cli_1',
        'session_name': 'Pi',
        'session_started_at': 1700000000000,
        'room_id': 'cwd-uuid-1234',
      };
      final m = PairOk.fromJson(j);
      expect(m.roomId, 'cwd-uuid-1234');
      expect(m.sessionName, 'Pi');
      expect(m.sessionStartedAt, 1700000000000);
    });
  });

  group('PeerRecord — roomId', () {
    test('roundtrip preserves roomId', () {
      const peer = PeerRecord(
        remoteEpk: 'epk_A',
        sessionName: 'Pi',
        endpoint: 'https://pc.example/baya-pair/wsl/direct',
        pairedAt: '2026-01-01T00:00:00Z',
        roomId: 'room-xyz',
      );
      final j = peer.toJson();
      final back = PeerRecord.fromJson(j);
      expect(back.roomId, 'room-xyz');
      expect(back, peer);
    });

    test('copyWith(roomId: ...) overrides; default keeps existing', () {
      const peer = PeerRecord(
        remoteEpk: 'epk_A',
        sessionName: 'Pi',
        endpoint: 'https://pc.example/baya-pair/wsl/direct',
        pairedAt: '2026-01-01T00:00:00Z',
        roomId: 'room-old',
      );
      // Default = keep
      final same = peer.copyWith(sessionName: 'Pi2');
      expect(same.roomId, 'room-old');
      // Explicit override
      final updated = peer.copyWith(roomId: 'room-new');
      expect(updated.roomId, 'room-new');
    });
  });
}
