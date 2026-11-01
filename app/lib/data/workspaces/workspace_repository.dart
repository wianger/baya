import 'dart:async';
import 'agent_catalog.dart';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/value_objects/session_room.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/protocol/uuid7.dart';

class WorkspaceRepository extends IWorkspaceRepository {
  WorkspaceRepository(
    this._connection,
    this._storage,
    this._preferences, {
    this.timeout = const Duration(seconds: 25),
  });
  final ConnectionManager _connection;
  final PairingStorage _storage;
  final Preferences _preferences;
  final Duration timeout;
  int _generation = 0;
  Future<void> _connectionQueue = Future<void>.value();

  void _ensureCurrent(int generation) {
    if (generation != _generation) {
      throw const WorkspaceFailure('Folder request cancelled.');
    }
  }

  // A slow switch must finish before a restore/new switch can take ownership.
  // Invalidated requests never change the room or send on the newer channel.
  Future<void> _switchConnection(
    PeerRecord peer,
    String roomId,
    int generation,
  ) {
    final operation = _connectionQueue.then((_) async {
      _ensureCurrent(generation);
      await _connection.switchTo(peer.copyWith(roomId: roomId));
      _ensureCurrent(generation);
      _connection.switchRoom(roomId);
    });
    _connectionQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  WorkspaceSelection? get currentSelection {
    final peer = _connection.activePeer;
    return peer == null
        ? null
        : WorkspaceSelection(peer.remoteEpk, _connection.activeRoomId);
  }

  String _label(PeerRecord peer) {
    if (peer.nickname?.isNotEmpty == true) return peer.nickname!;
    return peer.sessionName;
  }

  bool _online(PeerRecord peer) => _connection
      .conversationRoomsFor(peer.remoteEpk)
      .any((room) => _connection.isRoomLive(peer.remoteEpk, room.roomId));

  @override
  Future<List<WorkspaceHost>> listHosts() async {
    final peers = await _storage.listPeers();
    _connection.subscribeToPeers(peers.map((peer) => peer.remoteEpk).toList());
    return peers
        .map(
          (peer) => WorkspaceHost(
            id: peer.remoteEpk,
            label: _label(peer),
            online: _online(peer),
          ),
        )
        .toList();
  }

  Future<PeerRecord> _peer(String hostId) async {
    final peers = await _storage.listPeers();
    for (final peer in peers) {
      if (toStandardB64(peer.remoteEpk) == toStandardB64(hostId)) return peer;
    }
    throw const WorkspaceFailure(
      'Pair this computer before opening a session.',
    );
  }

  Future<IChannel> _connect(String hostId, int generation) async {
    final peer = await _peer(hostId);
    _ensureCurrent(generation);
    final rooms = _connection
        .conversationRoomsFor(peer.remoteEpk)
        .where((room) => _connection.isRoomLive(peer.remoteEpk, room.roomId))
        .toList();
    if (rooms.isEmpty) {
      throw const WorkspaceFailure(
        'This computer is offline. Start Baya on the computer and try again.',
      );
    }
    final current = _connection.activeRoomId;
    final room = rooms.firstWhere(
      (entry) => entry.roomId == current,
      orElse: () => rooms.first,
    );
    await _switchConnection(peer, room.roomId, generation);
    _ensureCurrent(generation);
    final channel = _connection.channel;
    if (channel == null) {
      throw const WorkspaceFailure('Could not connect to this computer.');
    }
    return channel;
  }

  Future<Map<String, dynamic>> _request(
    String hostId,
    ClientMessage Function(String) makeMessage,
    int generation,
  ) async {
    final channel = await _connect(hostId, generation);
    _ensureCurrent(generation);
    final id = uuid7();
    final completer = Completer<Map<String, dynamic>>();
    late final StreamSubscription<ServerMessage> subscription;
    subscription = channel.serverMessages.listen(
      (message) {
        switch (message) {
          case WorkspaceListing(:final inReplyTo, :final directory)
              when inReplyTo == id:
            if (!completer.isCompleted) completer.complete(directory);
          case WorkspaceOpened(:final inReplyTo, :final workspace)
              when inReplyTo == id:
            if (!completer.isCompleted) completer.complete(workspace);
          case WorkspaceError(:final inReplyTo, :final error)
              when inReplyTo == id:
            if (!completer.isCompleted) {
              completer.completeError(WorkspaceFailure(error));
            }
          case ErrorMessage(:final inReplyTo, :final message)
              when inReplyTo == id:
            if (!completer.isCompleted) {
              completer.completeError(WorkspaceFailure(message));
            }
          default:
            break;
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            const WorkspaceFailure('The computer disconnected.'),
          );
        }
      },
      onError: (Object _, StackTrace _) {
        if (!completer.isCompleted) {
          completer.completeError(
            const WorkspaceFailure('The computer disconnected.'),
          );
        }
      },
    );
    // Observe reply errors immediately: a synchronous channel can reply while
    // send() is still completing. Keep those errors on the awaited chain.
    final reply = completer.future.timeout(
      timeout,
      onTimeout: () {
        throw const WorkspaceFailure(
          'The computer did not respond. Update Baya on the computer and reconnect.',
        );
      },
    );
    try {
      final results = await Future.wait<dynamic>([
        reply,
        channel.send(makeMessage(id)),
      ], eagerError: true);
      _ensureCurrent(generation);
      return results.first as Map<String, dynamic>;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<WorkspaceDirectory> browse(
    String hostId, {
    String? path,
    bool showHidden = false,
  }) async {
    final generation = ++_generation;
    try {
      final data = await _request(
        hostId,
        (id) => WorkspaceBrowse(id: id, path: path, showHidden: showHidden),
        generation,
      );
      final directories = (data['directories'] as List).cast<Map>();
      return WorkspaceDirectory(
        path: data['path'] as String,
        home: data['home'] as String,
        parent: data['parent'] as String?,
        roots: (data['roots'] as List).cast<String>(),
        folders: directories
            .map(
              (entry) => WorkspaceFolder(
                name: entry['name'] as String,
                path: entry['path'] as String,
              ),
            )
            .toList(),
        agents: decodeWorkspaceAgents(data['agents']),
        truncated: data['truncated'] == true,
      );
    } on WorkspaceFailure {
      rethrow;
    } catch (_) {
      throw const WorkspaceFailure(
        'Could not read the folders on this computer.',
      );
    }
  }

  @override
  Future<OpenedWorkspace> open(
    String hostId,
    String path,
    WorkspaceAgent agent,
  ) async {
    final generation = ++_generation;
    final peer = await _peer(hostId);
    _ensureCurrent(generation);
    final hadLiveSession = _connection
        .conversationRoomsFor(hostId)
        .any(
          (room) =>
              room.cwd == path &&
              matchesLegacyWorkspaceAgent(room.name, agent) &&
              _connection.isRoomLive(hostId, room.roomId),
        );

    // Always ask the host to open the folder. The historical shortcut below
    // reused whichever room happened to be live, which made New Session open
    // the previous conversation instead of replacing it.
    final result = await _request(
      hostId,
      (id) => WorkspaceOpen(id: id, path: path, agent: agent.id),
      generation,
    );
    final routeId = result['room_id'] as String;
    final cwd = result['cwd'] as String;
    final name = result['name'] as String;
    final ready = await _waitForWorkspaceRoom(
      hostId,
      routeId: routeId,
      path: cwd,
      name: name,
      agent: agent,
      generation: generation,
    );

    // Older hosts omit `existing`; the live-room snapshot keeps this fix
    // working with them. Updated hosts also detect registered-but-stopped
    // agents that resumed their previous conversation on startup.
    final shouldStartFresh = result['existing'] == true || hadLiveSession;
    var roomId = ready.roomId;
    if (shouldStartFresh) {
      _ensureCurrent(generation);
      await _switchConnection(peer, roomId, generation);
      final channel = _connection.channel;
      if (channel == null) {
        throw const WorkspaceFailure('Could not connect to this computer.');
      }
      await _requestFreshSession(channel, generation);
      if (agent.id == 'pi') {
        final fresh = await _waitForFreshPiRoom(
          hostId,
          previousRoom: ready,
          routeId: routeId,
          path: cwd,
          agent: agent,
          generation: generation,
        );
        roomId = fresh.roomId;
      }
    }
    _ensureCurrent(generation);
    await _preferences.restoreSession(peer.remoteEpk, roomId);
    await _preferences.setSelectedRoom(epk: peer.remoteEpk, roomId: roomId);
    await _switchConnection(peer, roomId, generation);
    return OpenedWorkspace(
      hostId: peer.remoteEpk,
      hostLabel: _label(peer),
      path: cwd,
      roomId: roomId,
      name: name,
      agent: agent,
    );
  }

  Future<RoomInfo> _waitForWorkspaceRoom(
    String hostId, {
    required String routeId,
    required String path,
    required String name,
    required WorkspaceAgent agent,
    required int generation,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      _ensureCurrent(generation);
      for (final room in _connection.conversationRoomsFor(hostId)) {
        if (_roomMatchesTarget(room, routeId, path, name, agent) &&
            _connection.isRoomLive(hostId, room.roomId)) {
          return room;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw WorkspaceFailure(
      '${agent.label} did not come online. Check its sign-in and startup on the computer, then try again.',
    );
  }

  Future<RoomInfo> _waitForFreshPiRoom(
    String hostId, {
    required RoomInfo previousRoom,
    required String routeId,
    required String path,
    required WorkspaceAgent agent,
    required int generation,
  }) async {
    final previousConversation = conversationRoomId(previousRoom.roomId);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      _ensureCurrent(generation);
      for (final room in _connection.conversationRoomsFor(hostId)) {
        if (conversationRoomId(room.roomId) != previousConversation &&
            _roomMatchesTarget(
              room,
              routeId,
              path,
              previousRoom.name ?? agent.label,
              agent,
            ) &&
            _connection.isRoomLive(hostId, room.roomId)) {
          return room;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const WorkspaceFailure(
      'The Pi session started, but Baya could not connect to it. Try again.',
    );
  }

  bool _roomMatchesTarget(
    RoomInfo room,
    String routeId,
    String path,
    String name,
    WorkspaceAgent agent,
  ) {
    if (room.roomId == routeId ||
        legacyPiInstanceRoomId(room.roomId) == routeId) {
      return true;
    }
    return room.cwd == path &&
        (room.name == name || matchesLegacyWorkspaceAgent(room.name, agent));
  }

  Future<void> _requestFreshSession(IChannel channel, int generation) async {
    final id = uuid7();
    final completer = Completer<void>();
    late final StreamSubscription<ServerMessage> subscription;
    subscription = channel.serverMessages.listen(
      (message) {
        switch (message) {
          case ActionOk(:final inReplyTo) when inReplyTo == id:
            if (!completer.isCompleted) completer.complete();
          case ActionError(:final inReplyTo, :final error) when inReplyTo == id:
            if (!completer.isCompleted) {
              completer.completeError(
                WorkspaceFailure(
                  error.isEmpty ? 'Could not start a new session.' : error,
                ),
              );
            }
          case ErrorMessage(:final inReplyTo, :final message)
              when inReplyTo == id:
            if (!completer.isCompleted) {
              completer.completeError(WorkspaceFailure(message));
            }
          default:
            break;
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            const WorkspaceFailure(
              'The computer disconnected while starting a new session.',
            ),
          );
        }
      },
      onError: (Object _, StackTrace _) {
        if (!completer.isCompleted) {
          completer.completeError(
            const WorkspaceFailure(
              'The computer disconnected while starting a new session.',
            ),
          );
        }
      },
    );
    final reply = completer.future.timeout(
      timeout,
      onTimeout: () {
        throw const WorkspaceFailure(
          'The computer did not start a new session in time. Try again.',
        );
      },
    );
    try {
      await Future.wait<void>([
        reply,
        channel.send(SessionNew(id: id)),
      ], eagerError: true);
      _ensureCurrent(generation);
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> restore(WorkspaceSelection? selection) async {
    final generation = ++_generation;
    if (selection == null) return;
    final peer = await _peer(selection.hostId);
    await _switchConnection(peer, selection.roomId, generation);
  }
}
