import 'dart:async';
import 'dart:convert';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/value_objects/session_room.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _Channel implements IChannel, IControlLink {
  final messages = StreamController<ServerMessage>.broadcast();
  final control = StreamController<ControlInbound>.broadcast();
  final sent = <ClientMessage>[];
  String room = '';
  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Stream<ControlInbound> get controlFrames => control.stream;
  void setActiveRoom(String value) => room = value;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> send(ClientMessage message) async => sent.add(message);
  @override
  Future<void> close() async {}
}

class _Storage extends PairingStorage {
  _Storage(this.peer);
  final PeerRecord peer;
  @override
  Future<List<PeerRecord>> listPeers() async => [peer];
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => [];
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}
}

void main() {
  const daemon = 'pi_abcdefghijklmnop_d_ABCDEFGHIJKL';
  const terminal = 'pi_abcdefghijklmnop_i_MNOPQRSTUVWX';
  const other = 'pi_ABCDEFGHIJKLMNOP_i_ABCDEFGHIJKL';
  test('route changes reuse conversation cache while legacy and other sessions stay separate', () {
    expect(conversationRoomId(daemon), conversationRoomId(terminal));
    expect(
      LocalBoxes.msgsBoxName('AQ==', daemon),
      LocalBoxes.msgsBoxName('AQ==', terminal),
    );
    expect(
      LocalBoxes.sessionKey('AQ==', daemon),
      LocalBoxes.sessionKey('AQ==', terminal),
    );
    expect(
      LocalBoxes.msgsBoxName('AQ==', daemon),
      isNot(LocalBoxes.msgsBoxName('AQ==', other)),
    );
    expect(conversationRoomId('legacy-room'), 'legacy-room');
  });
  test('session key remains authoritative across alternate route suffixes', () {
    const daemon = 'pi_abcdefghijklmnop_d_A';
    const terminal = 'pi_abcdefghijklmnop_i_a-future_route-with_many-parts';

    expect(conversationRoomId(daemon), 'pi_abcdefghijklmnop');
    expect(conversationRoomId(terminal), 'pi_abcdefghijklmnop');
    expect(isInteractivePiRoom(daemon), isFalse);
    expect(isInteractivePiRoom(terminal), isTrue);
    expect(legacyPiInstanceRoomId(daemon), 'A');
    expect(legacyPiInstanceRoomId(terminal), 'a-future_route-with_many-parts');
  });
  test('mobile daemon plus desktop resume yields one row and one routing destination', () async {
    final peer = PeerRecord(
      remoteEpk: base64Encode(List.filled(32, 1)),
      sessionName: 'computer',
      relayUrl: 'https://example.invalid',
      pairedAt: '',
      roomId: daemon,
    );
    final channel = _Channel();
    final conn = ConnectionManager(
      storage: _Storage(peer),
      emitDebounce: Duration.zero,
      factory: (_, _) async => channel,
    );
    conn.adopt(channel, peer);
    void announce(String id, {bool working = false}) => channel.control.add(
      RoomAnnounced(
        peer: peer.remoteEpk,
        roomId: id,
        name: 'project',
        cwd: '/tmp/project',
        startedAt: 1,
        working: working,
      ),
    );
    announce('ABCDEFGHIJKL');
    channel.control.add(
      RoomEnded(peer: peer.remoteEpk, roomId: 'ABCDEFGHIJKL', sinceTs: 1),
    );
    announce(daemon);
    announce(terminal);
    announce(other);
    await Future<void>.delayed(Duration.zero);
    expect(
      conn.conversationRoomsFor(peer.remoteEpk).map((r) => r.roomId),
      unorderedEquals([terminal, other]),
    );
    expect(conn.roomsSnapshot.values.single, hasLength(2));
    conn.switchRoom(terminal);
    expect(channel.room, terminal);
    expect(channel.room, isNot(daemon));
    announce(daemon, working: true);
    await Future<void>.delayed(Duration.zero);
    expect(
      conn.conversationRoomsFor(peer.remoteEpk).any((r) => r.roomId == daemon),
      isTrue,
      reason: 'do not hide the instance that is currently answering',
    );
    channel.control.add(
      RoomEnded(peer: peer.remoteEpk, roomId: daemon, sinceTs: 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      conn
          .conversationRoomsFor(peer.remoteEpk)
          .any((r) => r.roomId == terminal),
      isTrue,
    );
    conn.dispose();
    await channel.messages.close();
    await channel.control.close();
  });
  test(
    'live legacy route yields to a session-bound route for the same cwd',
    () async {
      final peer = PeerRecord(
        remoteEpk: base64Encode(List.filled(32, 2)),
        sessionName: 'computer',
        relayUrl: 'https://example.invalid',
        pairedAt: '',
        roomId: 'ABCDEFGHIJKL',
      );
      final channel = _Channel();
      final conn = ConnectionManager(
        storage: _Storage(peer),
        emitDebounce: Duration.zero,
        factory: (_, _) async => channel,
      );
      conn.adopt(channel, peer);
      void announce(String id, {int startedAt = 1}) => channel.control.add(
        RoomAnnounced(
          peer: peer.remoteEpk,
          roomId: id,
          name: 'project',
          cwd: r'C:\code\project',
          startedAt: startedAt,
        ),
      );

      announce('ABCDEFGHIJKL');
      announce(daemon, startedAt: 2);
      await Future<void>.delayed(Duration.zero);

      expect(conn.conversationRoomsFor(peer.remoteEpk).map((r) => r.roomId), [
        daemon,
      ]);
      expect(conn.roomsFor(peer.remoteEpk), hasLength(2));
      conn.dispose();
      await channel.messages.close();
      await channel.control.close();
    },
  );
  test(
    'different sessions in one directory remain separate and same-session '
    'endpoints choose the interactive route when neither is working',
    () async {
      final peer = PeerRecord(
        remoteEpk: base64Encode(List.filled(32, 3)),
        sessionName: 'computer',
        relayUrl: 'https://example.invalid',
        pairedAt: '',
        roomId: daemon,
      );
      final channel = _Channel();
      final conn = ConnectionManager(
        storage: _Storage(peer),
        emitDebounce: Duration.zero,
        factory: (_, _) async => channel,
      );
      conn.adopt(channel, peer);
      void announce(String id, {int startedAt = 1}) => channel.control.add(
        RoomAnnounced(
          peer: peer.remoteEpk,
          roomId: id,
          name: 'project',
          cwd: '/tmp/project',
          startedAt: startedAt,
        ),
      );

      announce(daemon, startedAt: 2);
      announce(terminal);
      announce(other);
      await Future<void>.delayed(Duration.zero);

      expect(
        conn.conversationRoomsFor(peer.remoteEpk).map((r) => r.roomId),
        unorderedEquals([terminal, other]),
      );
      conn.dispose();
      await channel.messages.close();
      await channel.control.close();
    },
  );
}
