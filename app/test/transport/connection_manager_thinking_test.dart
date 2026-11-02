// ConnectionManager propagates thinking from `room_announced` and
// `room_meta_updated` into RoomInfo.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _fakePeer() => const PeerRecord(
  remoteEpk: 'epk_test',
  sessionName: 'pi',
  endpoint: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
  roomId: 'main',
);

class _FakeStorage extends PairingStorage {
  final List<PeerRecord> peers;
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => peers;

  @override
  Future<void> savePeer(PeerRecord r) async {}

  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];

  @override
  Future<void> deleteRooms(String epk) async {}
}

class _ControllableChannel implements IChannel, IControlLink {
  final _serverCtrl = StreamController<ServerMessage>.broadcast();
  final _controlCtrl = StreamController<ControlInbound>.broadcast();

  @override
  Stream<ServerMessage> get serverMessages => _serverCtrl.stream;

  @override
  Stream<ControlInbound> get controlFrames => _controlCtrl.stream;

  @override
  Future<void> send(ClientMessage msg) async {}

  @override
  void sendControl(Map<String, dynamic> json) {}

  @override
  Future<void> close() async {
    await _serverCtrl.close();
    await _controlCtrl.close();
  }

  // ignore: unused_element
  void pushServer(ServerMessage m) => _serverCtrl.add(m);
  void pushControl(ControlInbound m) => _controlCtrl.add(m);

  // Avoid analyzer "unused" on the import.
  // ignore: unused_element
  Uint8List _placeholder() => Uint8List(0);
}

void main() {
  group('ConnectionManager — thinking propagation', () {
    test('RoomAnnounced with thinking seeds RoomInfo.thinking', () async {
      final ch = _ControllableChannel();
      final cm = ConnectionManager(
        factory: (_, _) async => ch,
        storage: _FakeStorage([_fakePeer()]),
        emitDebounce: Duration.zero,
      );
      await cm.connectTo(_fakePeer());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_test',
          room: RoomInfo(
            roomId: 'r1',
            startedAt: 1,
            model: 'claude-opus-4-7',
            thinking: ThinkingLevel.high,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final room = cm.roomsFor('epk_test').single;
      expect(room.thinking, ThinkingLevel.high);
      expect(room.model, 'claude-opus-4-7');

      cm.dispose();
    });
  });
}
