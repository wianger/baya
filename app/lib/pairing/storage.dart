import 'dart:convert';

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/protocol/protocol.dart' show PiHarness;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _kPeersService = 'dev.wianger.baya.peers';
const _kRoomsService = 'dev.wianger.baya.rooms';

/// Persisted snapshot of every room we have ever
/// learned about for a peer (relay-announced via `room_announced` /
/// `rooms` push). Allows Home to keep showing the same tiles after a
/// cold start while the relay is still warming up + lets the user
/// open a chat offline and read history.
class PersistedRoom {
  final String roomId;
  final String? name;
  final String? cwd;
  final int startedAt;

  /// Local-only override for [name]. When non-null, takes precedence
  /// in UI (long-press rename).
  final String? localName;

  /// Last-known model the Pi-extension is running with.
  /// Persisted so the subtitle survives cold starts.
  final String? model;

  const PersistedRoom({
    required this.roomId,
    required this.startedAt,
    this.name,
    this.cwd,
    this.localName,
    this.model,
  });

  Map<String, dynamic> toJson() => {
    'room_id': roomId,
    'name': name,
    'cwd': cwd,
    'started_at': startedAt,
    'local_name': localName,
    'model': model,
  };

  factory PersistedRoom.fromJson(Map<String, dynamic> j) => PersistedRoom(
    roomId: j['room_id'] as String,
    name: j['name'] as String?,
    cwd: j['cwd'] as String?,
    startedAt: (j['started_at'] as num).toInt(),
    localName: j['local_name'] as String?,
    model: j['model'] as String?,
  );

  PersistedRoom copyWith({
    String? name,
    String? cwd,
    int? startedAt,
    Object? localName = _unset,
    Object? model = _unset,
  }) => PersistedRoom(
    roomId: roomId,
    name: name ?? this.name,
    cwd: cwd ?? this.cwd,
    startedAt: startedAt ?? this.startedAt,
    localName: identical(localName, _unset)
        ? this.localName
        : localName as String?,
    model: identical(model, _unset) ? this.model : model as String?,
  );
}

// ---------------------------------------------------------------------------
// PeerRecord — persisted per pairing
// ---------------------------------------------------------------------------

// Sentinel for nullable copyWith parameters that need to distinguish
// "keep current" (omit) from "set to null" (pass `null` explicitly).
const Object _unset = Object();

class PeerRecord {
  // base64 Ed25519 pubkey of the Pi — the only peer identifier post-rollback.
  final String remoteEpk;
  final String sessionName;
  final String endpoint;
  final String pairedAt; // ISO-8601
  // Local-only display label (Pi does not know about this). Renders in
  // place of [sessionName] when set; null = use sessionName everywhere.
  final String? nickname;

  /// Room of the session this pairing addresses (from `pair_ok`, then the
  /// last opened session). `null` only for records built by mesh sync before
  /// a session is chosen.
  final String? roomId;

  /// Agent harness reported by the PC at pair time.
  /// Surfaced as the "via Pi coding agent" subtitle on the PiCard.
  /// `null` for PeerRecords saved before the field existed; consumers
  /// fall back to [PiHarness.piCodingAgentUnknown] so the UI never
  /// renders an empty subtitle.
  final PiHarness? harness;

  const PeerRecord({
    required this.remoteEpk,
    required this.sessionName,
    required this.endpoint,
    required this.pairedAt,
    this.nickname,
    this.roomId,
    this.harness,
  });

  Map<String, dynamic> toJson() => {
    'remote_epk': remoteEpk,
    'session_name': sessionName,
    'endpoint': endpoint,
    'paired_at': pairedAt,
    'nickname': nickname,
    'room_id': roomId,
    if (harness != null) 'harness': harness!.toJson(),
  };

  factory PeerRecord.fromJson(Map<String, dynamic> j) {
    final harnessJson = j['harness'];
    return PeerRecord(
      remoteEpk: j['remote_epk'] as String,
      sessionName: j['session_name'] as String,
      endpoint: j['endpoint'] as String,
      pairedAt: j['paired_at'] as String,
      nickname: j['nickname'] as String?,
      roomId: j['room_id'] as String?,
      harness: harnessJson is Map<String, dynamic>
          ? PiHarness.fromJson(harnessJson)
          : null,
    );
  }

  PeerRecord copyWith({
    String? sessionName,
    // Sentinel-typed so the caller can pass `nickname: null` to clear.
    Object? nickname = _unset,
    Object? roomId = _unset,
    Object? harness = _unset,
  }) => PeerRecord(
    remoteEpk: remoteEpk,
    sessionName: sessionName ?? this.sessionName,
    endpoint: endpoint,
    pairedAt: pairedAt,
    nickname: identical(nickname, _unset) ? this.nickname : nickname as String?,
    roomId: identical(roomId, _unset) ? this.roomId : roomId as String?,
    harness: identical(harness, _unset) ? this.harness : harness as PiHarness?,
  );

  @override
  bool operator ==(Object other) =>
      other is PeerRecord &&
      other.remoteEpk == remoteEpk &&
      other.sessionName == sessionName &&
      other.endpoint == endpoint &&
      other.pairedAt == pairedAt &&
      other.nickname == nickname &&
      other.roomId == roomId &&
      other.harness == harness;

  @override
  int get hashCode => Object.hash(
    remoteEpk,
    sessionName,
    endpoint,
    pairedAt,
    nickname,
    roomId,
    harness,
  );
}

// ---------------------------------------------------------------------------
// PairingStorage
// ---------------------------------------------------------------------------

/// Pairing storage with change notification.
///
/// Mutations to the peer set (`savePeer`, `deletePeer`) and to the
/// per-peer rooms cache (`saveRooms`, `deleteRooms`) call
/// `notifyListeners()` so any UI watching the storage (HomeViewModel,
/// SettingsViewModel) can refresh without manual plumbing between
/// screens. Read methods do not notify.
class PairingStorage extends ChangeNotifier {
  final FlutterSecureStorage _store;

  /// Optional fire-and-forget hook that runs after every
  /// peer mutation (`savePeer` / `deletePeer`). The `MeshSyncService`
  /// registers this so changes propagate to the relay's
  /// `mesh_versions` row in the background. Failures of the hook are
  /// the hook's problem — local mutation is already committed and
  /// observers were notified by the time the hook fires.
  ///
  /// Room mutations are intentionally NOT hooked — rooms are a
  /// per-device cache, not synced membership.
  void Function()? _onPeersMutated;

  PairingStorage([FlutterSecureStorage? store])
    : _store = store ?? const FlutterSecureStorage();

  /// Plug the mesh-publish callback. The hook fires after the local
  /// write completes and after [notifyListeners], so UI sees the
  /// change before the relay does. Pass `null` to detach.
  void attachPeerMutationHook(void Function()? hook) {
    _onPeersMutated = hook;
  }

  // ---- Peer records --------------------------------------------------------

  String _canonicalEpk(String remoteEpk) => toStandardB64(remoteEpk);

  String _peerKey(String remoteEpk) =>
      '$_kPeersService:${_canonicalEpk(remoteEpk)}';

  Future<void> savePeer(PeerRecord record) async {
    await _writePeer(record);
    _onPeersMutated?.call();
  }

  /// Same as [savePeer] but skips the mutation hook. Used by the
  /// MeshSyncService when applying a verified mesh blob to the local
  /// cache — without this we'd round-trip back to the relay
  /// (pull→apply→savePeer→hook→publish) and a race could publish an
  /// empty members list.
  Future<void> savePeerSilent(PeerRecord record) => _writePeer(record);

  Future<PeerRecord?> loadPeer(String remoteEpk) async {
    final canonical = _canonicalEpk(remoteEpk);
    for (final record in await listPeers()) {
      if (_canonicalEpk(record.remoteEpk) == canonical) return record;
    }
    return null;
  }

  Future<void> deletePeer(String remoteEpk) async {
    await _erasePeer(remoteEpk);
    _onPeersMutated?.call();
  }

  /// Same as [deletePeer] but skips the mutation hook — see
  /// [savePeerSilent] for the rationale.
  Future<void> deletePeerSilent(String remoteEpk) => _erasePeer(remoteEpk);

  /// Re-emit the peer set after a caller uses [deletePeerSilent] and handles
  /// mesh publication itself.
  void notifyPeersChanged() => notifyListeners();

  Future<void> _writePeer(PeerRecord record) async {
    await _store.write(
      key: _peerKey(record.remoteEpk),
      value: jsonEncode(record.toJson()),
    );
    notifyListeners();
  }

  Future<void> _erasePeer(String remoteEpk) async {
    await _store.delete(key: _peerKey(remoteEpk));
    notifyListeners();
  }

  Future<List<PeerRecord>> listPeers() async {
    final all = await _store.readAll();
    final prefix = '$_kPeersService:';
    final peers = <PeerRecord>[];
    for (final entry in all.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      try {
        peers.add(
          PeerRecord.fromJson(jsonDecode(entry.value) as Map<String, dynamic>),
        );
      } catch (_) {
        // Written by an earlier development build: unreadable, pair again.
      }
    }
    return peers;
  }

  /// Wipe every peer + every persisted room map. Used by the
  /// Owner-key bridge when Backup sync brings a different
  /// Owner-pk — the previous device's peer list is meaningless for
  /// the newly-synced identity, so we start clean rather than risk
  /// connecting against stale `remote_epk`s.
  Future<void> wipeAll() async {
    final all = await _store.readAll();
    final prefixes = ['$_kPeersService:', '$_kRoomsService:'];
    for (final key in all.keys) {
      if (prefixes.any(key.startsWith)) {
        await _store.delete(key: key);
      }
    }
    notifyListeners();
  }

  // ---- Rooms -----------------------------------------

  String _roomsKey(String remoteEpk) => '$_kRoomsService:$remoteEpk';

  /// Persist the full set of known rooms for a peer. Replaces any
  /// previously stored set. Called on every room-state change in
  /// ConnectionManager so a cold start can reflect the same view.
  Future<void> saveRooms(String remoteEpk, List<PersistedRoom> rooms) async {
    await _store.write(
      key: _roomsKey(remoteEpk),
      value: jsonEncode(rooms.map((r) => r.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<List<PersistedRoom>> loadRooms(String remoteEpk) async {
    final raw = await _store.read(key: _roomsKey(remoteEpk));
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => PersistedRoom.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteRooms(String remoteEpk) async {
    await _store.delete(key: _roomsKey(remoteEpk));
    notifyListeners();
  }
}
