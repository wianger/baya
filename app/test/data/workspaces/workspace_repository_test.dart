import 'dart:async';
import 'dart:convert';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/workspaces/workspace_repository.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Channel implements IChannel, IControlLink {
  _Channel({this.onSend});

  final messages = StreamController<ServerMessage>.broadcast();
  final control = StreamController<ControlInbound>.broadcast();
  final sent = <ClientMessage>[];
  final void Function(ClientMessage message)? onSend;
  String room = '';
  @override
  Stream<ServerMessage> get serverMessages => messages.stream;
  @override
  Stream<ControlInbound> get controlFrames => control.stream;
  void setActiveRoom(String value) => room = value;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> send(ClientMessage message) async {
    sent.add(message);
    onSend?.call(message);
  }

  @override
  Future<void> close() async {}
}

class _Storage extends PairingStorage {
  _Storage(this.peers);
  final List<PeerRecord> peers;
  @override
  Future<List<PeerRecord>> listPeers() async => peers;
  @override
  Future<List<PersistedRoom>> loadRooms(String remoteEpk) async => [];
  @override
  Future<void> saveRooms(String remoteEpk, List<PersistedRoom> rooms) async {}
}

class _SecureStorage implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'opening a folder with an existing Pi session starts a new room',
    () async {
      const routeId = 'abcdefghijkl';
      const oldRoomId = 'pi_AAAAAAAAAAAAAAAA_d_$routeId';
      const freshRoomId = 'pi_BBBBBBBBBBBBBBBB_i_$routeId';
      const cwd = '/project';
      const name = 'Pi · project';
      final a = PeerRecord(
        remoteEpk: base64Encode(List.filled(32, 1)),
        sessionName: name,
        roomId: oldRoomId,
        relayUrl: 'https://example.invalid',
        pairedAt: '2026-10-30',
      );
      late final _Channel channel;
      channel = _Channel(
        onSend: (message) {
          switch (message) {
            case WorkspaceOpen():
              channel.messages.add(
                WorkspaceOpened(
                  inReplyTo: message.id,
                  workspace: const {
                    'room_id': routeId,
                    'cwd': cwd,
                    'name': name,
                    'existing': true,
                  },
                ),
              );
            case SessionNew():
              channel.messages.add(
                ActionOk(
                  inReplyTo: message.id,
                  action: ActionName.sessionNew,
                  rawAction: 'session_new',
                ),
              );
              channel.control.add(
                RoomAnnounced(
                  peer: a.remoteEpk,
                  roomId: freshRoomId,
                  name: name,
                  cwd: cwd,
                  startedAt: 2,
                ),
              );
            default:
              break;
          }
        },
      );
      final storage = _Storage([a]);
      final conn = ConnectionManager(
        storage: storage,
        emitDebounce: Duration.zero,
        factory: (_, _) async => channel,
      );
      final prefs = Preferences(_SecureStorage());
      final repo = WorkspaceRepository(conn, storage, prefs);
      conn.adopt(channel, a);
      conn.switchRoom(oldRoomId);
      channel.control.add(
        RoomAnnounced(
          peer: a.remoteEpk,
          roomId: oldRoomId,
          name: name,
          cwd: cwd,
          startedAt: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final opened = await repo.open(a.remoteEpk, cwd, WorkspaceAgent.pi);

      expect(channel.sent.whereType<WorkspaceOpen>(), hasLength(1));
      expect(channel.sent.whereType<SessionNew>(), hasLength(1));
      expect(opened.roomId, freshRoomId);
      expect(conn.activeRoomId, freshRoomId);

      conn.dispose();
      prefs.dispose();
      await channel.messages.close();
      await channel.control.close();
    },
  );

  test(
    'cancel restores A after a late B connection and sends no browse on A',
    () async {
      PeerRecord peer(int byte, String room) => PeerRecord(
        remoteEpk: base64Encode(List.filled(32, byte)),
        sessionName: room,
        roomId: room,
        relayUrl: 'https://example.invalid',
        pairedAt: '2026-10-30',
      );
      final a = peer(1, 'room-A'), b = peer(2, 'room-B');
      final channelA = _Channel(), channelB = _Channel();
      final bStarted = Completer<void>(), bConnected = Completer<IChannel>();
      final storage = _Storage([a, b]);
      final conn = ConnectionManager(
        storage: storage,
        emitDebounce: Duration.zero,
        factory: (peer, cancel) async {
          if (peer.remoteEpk == b.remoteEpk) {
            bStarted.complete();
            return bConnected.future;
          }
          return channelA;
        },
      );
      final prefs = Preferences();
      final repo = WorkspaceRepository(conn, storage, prefs);
      conn.adopt(channelA, a);
      conn.switchRoom(a.roomId!);
      channelA.control.add(
        RoomAnnounced(peer: b.remoteEpk, roomId: b.roomId!, startedAt: 1),
      );
      await Future<void>.delayed(Duration.zero);
      final browse = repo.browse(b.remoteEpk);
      final rejected = expectLater(browse, throwsA(isA<WorkspaceFailure>()));
      await bStarted.future;
      final restore = repo.restore(WorkspaceSelection(a.remoteEpk, a.roomId!));
      bConnected.complete(channelB);
      await Future.wait([restore, rejected]);
      expect(conn.activePeer!.remoteEpk, a.remoteEpk);
      expect(conn.activeRoomId, a.roomId);
      expect(channelA.room, a.roomId);
      expect(channelA.sent.whereType<WorkspaceBrowse>(), isEmpty);
      expect(channelB.sent.whereType<WorkspaceBrowse>(), isEmpty);
      conn.dispose();
      prefs.dispose();
      await channelA.messages.close();
      await channelA.control.close();
      await channelB.messages.close();
      await channelB.control.close();
    },
  );

  test('switching devices browses the selected computer', () async {
    PeerRecord peer(int byte, String room) => PeerRecord(
      remoteEpk: base64Encode(List.filled(32, byte)),
      sessionName: room,
      roomId: room,
      relayUrl: 'https://example.invalid',
      pairedAt: '2026-10-30',
    );
    final a = peer(1, 'room-A'), b = peer(2, 'room-B');
    late final _Channel channelA;
    late final _Channel channelB;
    channelA = _Channel();
    channelB = _Channel(
      onSend: (message) {
        if (message is WorkspaceBrowse) {
          channelB.messages.add(
            WorkspaceListing(
              inReplyTo: message.id,
              directory: const {
                'path': '/home-b',
                'home': '/home-b',
                'parent': null,
                'roots': ['/'],
                'directories': [
                  {'name': 'project', 'path': '/home-b/project'},
                ],
                'agents': [
                  {'id': 'pi', 'label': 'Pi', 'available': true},
                ],
                'truncated': false,
              },
            ),
          );
        }
      },
    );
    final storage = _Storage([a, b]);
    final conn = ConnectionManager(
      storage: storage,
      emitDebounce: Duration.zero,
      factory: (peer, _) async =>
          peer.remoteEpk == b.remoteEpk ? channelB : channelA,
    );
    final prefs = Preferences();
    final repo = WorkspaceRepository(conn, storage, prefs);
    conn.adopt(channelA, a);
    conn.switchRoom(a.roomId!);
    channelA.control.add(
      RoomAnnounced(peer: a.remoteEpk, roomId: a.roomId!, startedAt: 1),
    );
    channelA.control.add(
      RoomAnnounced(peer: b.remoteEpk, roomId: b.roomId!, startedAt: 1),
    );
    await Future<void>.delayed(Duration.zero);

    final directory = await repo.browse(b.remoteEpk);

    expect(directory.path, '/home-b');
    expect(conn.activePeer!.remoteEpk, b.remoteEpk);
    expect(conn.activeRoomId, b.roomId);
    expect(channelB.sent.whereType<WorkspaceBrowse>(), hasLength(1));
    expect(channelA.sent.whereType<WorkspaceBrowse>(), isEmpty);

    conn.dispose();
    prefs.dispose();
    await channelA.messages.close();
    await channelA.control.close();
    await channelB.messages.close();
    await channelB.control.close();
  });
}
