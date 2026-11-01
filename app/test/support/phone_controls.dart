import 'dart:async';
import 'dart:convert';
import 'package:app/data/transport/channel.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';

class PhoneTestChannel implements IChannel, IControlLink {
  final messages = StreamController<ServerMessage>.broadcast();
  final control = StreamController<ControlInbound>.broadcast();
  final sent = <ClientMessage>[];
  void Function(ClientMessage)? onSend;
  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Stream<ControlInbound> get controlFrames => control.stream;
  @override
  Future<void> send(ClientMessage message) async {
    sent.add(message);
    onSend?.call(message);
  }

  @override
  void sendControl(Map<String, dynamic> frame) {}
  @override
  Future<void> close() async {}
  Future<void> disposeStreams() async {
    await messages.close();
    await control.close();
  }

  void setActiveRoom(String room) {}
}

class PhoneTestStorage extends PairingStorage {
  PhoneTestStorage(this.peers);
  final List<PeerRecord> peers;
  final rooms = <String, List<PersistedRoom>>{};
  @override
  Future<List<PeerRecord>> listPeers() async => peers;
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => rooms[epk] ?? [];
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> value) async {
    rooms[epk] = value;
  }
}

PeerRecord phoneTestPeer({
  String room = 'pi_abcdefghijklmnop_d_ABCDEFGHIJKL',
}) => PeerRecord(
  remoteEpk: base64Encode(List.filled(32, 5)),
  sessionName: 'PC',
  roomId: room,
  relayUrl: 'https://example.invalid',
  pairedAt: '2026-10-30',
);
