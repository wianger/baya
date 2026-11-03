// Every paired computer, each with its own live connection: a phone paired
// with a Windows and a WSL Baya talks to both at once.

import 'dart:async';

import 'package:app/acp/acp.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/data/transport/host_socket.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter/foundation.dart';

/// A session and the computer it lives on.
class HostedSession {
  final HostConnection host;
  final SessionSummary session;
  const HostedSession(this.host, this.session);

  String get hostKey => host.key;
  String get sessionId => session.sessionId;
  bool get live => host.isOnline;
}

class Hosts extends ChangeNotifier {
  Hosts({
    required this._storage,
    required this._connect,
    required this._identity,
  });

  final PairingStorage _storage;
  final HostSocketFactory _connect;
  final IdentityLoader _identity;
  final _connections = <String, HostConnection>{};
  bool _started = false;
  bool _loaded = false;

  /// Paired computers, by label.
  List<HostConnection> get all => _connections.values.toList()
    ..sort(
      (a, b) =>
          a.host.label.toLowerCase().compareTo(b.host.label.toLowerCase()),
    );

  /// True once the paired computers were read from storage.
  bool get loaded => _loaded;

  bool get isEmpty => _connections.isEmpty;

  HostConnection? byKey(String? key) =>
      key == null ? null : _connections[toStandardB64(key)];

  /// Every session on every computer, newest first.
  List<HostedSession> get sessions =>
      [
        for (final host in _connections.values)
          for (final session in host.sessions) HostedSession(host, session),
      ]..sort(
        (a, b) => (b.session.updatedAt ?? DateTime(0)).compareTo(
          a.session.updatedAt ?? DateTime(0),
        ),
      );

  HostedSession? find(String hostKey, String sessionId) {
    final host = byKey(hostKey);
    final session = host?.session(sessionId);
    return host == null || session == null
        ? null
        : HostedSession(host, session);
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _storage.addListener(_sync);
    await _sync();
  }

  /// App back in the foreground: don't wait out a backoff.
  void reconnectAll() {
    for (final host in _connections.values) {
      host.reconnectNow();
    }
  }

  Future<void> _sync() async {
    final peers = await _storage.listPeers();
    final wanted = {for (final p in peers) toStandardB64(p.remoteEpk): p};
    var changed = !_loaded;
    for (final key in _connections.keys.toList()) {
      if (wanted.containsKey(key)) continue;
      final gone = _connections.remove(key)!;
      gone.removeListener(notifyListeners);
      gone.dispose();
      changed = true;
    }
    for (final MapEntry(:key, value: peer) in wanted.entries) {
      final existing = _connections[key];
      if (existing != null) {
        if (existing.host != peer) existing.updateHost(peer);
        continue;
      }
      final connection = HostConnection(
        host: peer,
        connect: _connect,
        identity: _identity,
        cache: _storage,
      )..addListener(notifyListeners);
      _connections[key] = connection;
      unawaited(connection.start());
      changed = true;
    }
    _loaded = true;
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _storage.removeListener(_sync);
    for (final host in _connections.values) {
      host.removeListener(notifyListeners);
      host.dispose();
    }
    _connections.clear();
    super.dispose();
  }
}
