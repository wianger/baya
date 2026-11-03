import 'dart:convert';

import 'package:app/acp/acp.dart';

import 'package:app/data/transport/epk_encoding.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _kPeersService = 'dev.wianger.baya.peers';
const _kSessionsService = 'dev.wianger.baya.sessions';

// ---------------------------------------------------------------------------
// PeerRecord — persisted per pairing
// ---------------------------------------------------------------------------

// Sentinel for nullable copyWith parameters that need to distinguish
// "keep current" (omit) from "set to null" (pass `null` explicitly).
const Object _unset = Object();

/// A paired computer.
class PeerRecord {
  /// The computer's Ed25519 public key (base64): its identity.
  final String remoteEpk;

  /// What the computer calls itself, e.g. `studio (WSL)`.
  final String name;

  /// Where the phone reaches it: the host's `…/direct` address.
  final String endpoint;
  final String pairedAt; // ISO-8601

  /// The user's own name for it; shown instead of [name] when set.
  final String? nickname;

  const PeerRecord({
    required this.remoteEpk,
    required this.name,
    required this.endpoint,
    required this.pairedAt,
    this.nickname,
  });

  String get label => nickname?.isNotEmpty == true ? nickname! : name;

  Map<String, dynamic> toJson() => {
    'remote_epk': remoteEpk,
    'name': name,
    'endpoint': endpoint,
    'paired_at': pairedAt,
    'nickname': nickname,
  };

  factory PeerRecord.fromJson(Map<String, dynamic> j) => PeerRecord(
    remoteEpk: j['remote_epk'] as String,
    name: j['name'] as String,
    endpoint: j['endpoint'] as String,
    pairedAt: j['paired_at'] as String,
    nickname: j['nickname'] as String?,
  );

  PeerRecord copyWith({
    String? name,
    // Sentinel-typed so the caller can pass `nickname: null` to clear.
    Object? nickname = _unset,
  }) => PeerRecord(
    remoteEpk: remoteEpk,
    name: name ?? this.name,
    endpoint: endpoint,
    pairedAt: pairedAt,
    nickname: identical(nickname, _unset) ? this.nickname : nickname as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is PeerRecord &&
      other.remoteEpk == remoteEpk &&
      other.name == name &&
      other.endpoint == endpoint &&
      other.pairedAt == pairedAt &&
      other.nickname == nickname;

  @override
  int get hashCode =>
      Object.hash(remoteEpk, name, endpoint, pairedAt, nickname);
}

// ---------------------------------------------------------------------------
// PairingStorage
// ---------------------------------------------------------------------------

/// Pairing storage with change notification.
///
/// Mutations to the peer set (`savePeer`, `deletePeer`) call
/// `notifyListeners()` so anything watching (the host connections, Settings)
/// follows without manual plumbing between screens.
class PairingStorage extends ChangeNotifier {
  final FlutterSecureStorage _store;

  PairingStorage([FlutterSecureStorage? store])
    : _store = store ?? const FlutterSecureStorage();

  // ---- Peer records --------------------------------------------------------

  String _canonicalEpk(String remoteEpk) => toStandardB64(remoteEpk);

  String _peerKey(String remoteEpk) =>
      '$_kPeersService:${_canonicalEpk(remoteEpk)}';

  Future<void> savePeer(PeerRecord record) async {
    await _store.write(
      key: _peerKey(record.remoteEpk),
      value: jsonEncode(record.toJson()),
    );
    notifyListeners();
  }

  Future<PeerRecord?> loadPeer(String remoteEpk) async {
    final canonical = _canonicalEpk(remoteEpk);
    for (final record in await listPeers()) {
      if (_canonicalEpk(record.remoteEpk) == canonical) return record;
    }
    return null;
  }

  Future<void> deletePeer(String remoteEpk) async {
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

  /// Wipe every peer and every cached session list. Used by the
  /// Owner-key bridge when Backup sync brings a different
  /// Owner-pk — the previous device's peer list is meaningless for
  /// the newly-synced identity, so we start clean rather than risk
  /// connecting against stale `remote_epk`s.
  Future<void> wipeAll() async {
    final all = await _store.readAll();
    final prefixes = ['$_kPeersService:', '$_kSessionsService:'];
    for (final key in all.keys) {
      if (prefixes.any(key.startsWith)) {
        await _store.delete(key: key);
      }
    }
    notifyListeners();
  }

  // ---- Session lists ------------------------------------------------------

  String _sessionsKey(String remoteEpk) =>
      '$_kSessionsService:${_canonicalEpk(remoteEpk)}';

  /// The computer's last known sessions, so Home shows them before (or
  /// without) a connection.
  Future<void> saveSessions(
    String remoteEpk,
    List<SessionSummary> sessions,
  ) async {
    await _store.write(
      key: _sessionsKey(remoteEpk),
      value: jsonEncode([for (final s in sessions) s.toJson()]),
    );
  }

  Future<List<SessionSummary>> loadSessions(String remoteEpk) async {
    try {
      final raw = await _store.read(key: _sessionsKey(remoteEpk));
      if (raw == null) return const [];
      return [
        for (final item in jsonDecode(raw) as List<dynamic>)
          SessionSummary.fromJson((item as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> deleteSessions(String remoteEpk) =>
      _store.delete(key: _sessionsKey(remoteEpk));
}
