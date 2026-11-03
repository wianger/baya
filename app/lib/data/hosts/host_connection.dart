// One paired computer, kept connected while the app runs.
//
// To the phone the computer is a single ACP agent: `initialize`, then
// `session/list` and live `_baya/session_changed` pushes keep [sessions]
// current; `session/update` and permission questions are routed to whoever
// has the session open.

import 'dart:async';

import 'package:app/acp/acp.dart';
import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transport/host_socket.dart';
import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

enum HostStatus {
  /// Trying to reach the computer.
  connecting,

  /// Connected and initialized.
  online,

  /// Unreachable; retrying with backoff.
  offline,

  /// The computer no longer knows this phone. Retrying cannot help.
  unpaired,
}

/// A `session/update` for one of this computer's sessions.
class SessionEvent {
  final String sessionId;
  final SessionUpdate update;
  const SessionEvent(this.sessionId, this.update);
}

/// A permission question arrived ([request] set) or was withdrawn.
class PermissionEvent {
  final PermissionRequest? request;
  final Object requestId;
  PermissionEvent.asked(PermissionRequest this.request)
    : requestId = request.requestId;
  const PermissionEvent.withdrawn(this.requestId) : request = null;
}

typedef IdentityLoader = Future<SimpleKeyPair> Function();

const _retryDelays = [1, 2, 5, 10, 20, 30];
const _callTimeout = Duration(seconds: 30);

class HostConnection extends ChangeNotifier {
  HostConnection({
    required this._host,
    required this._connect,
    required this._identity,
    this._cache,
  });

  PeerRecord _host;
  final HostSocketFactory _connect;
  final IdentityLoader _identity;
  final PairingStorage? _cache;

  HostSocket? _socket;
  JsonRpcPeer? _peer;
  Timer? _retry;
  int _attempt = 0;
  bool _stopped = false;

  HostStatus _status = HostStatus.connecting;
  String? _error;
  int? _clockSkewMinutes;
  HostIntro? _intro;
  List<SessionSummary> _sessions = const [];
  final _pendingPermissions = <Object, Completer<Json>>{};
  final _askedPermissions = <Object, PermissionRequest>{};

  final _updates = StreamController<SessionEvent>.broadcast();
  final _permissions = StreamController<PermissionEvent>.broadcast();
  final _online = StreamController<void>.broadcast();

  PeerRecord get host => _host;
  String get key => _host.remoteEpk;
  HostStatus get status => _status;
  bool get isOnline => _status == HostStatus.online;

  /// Why the last attempt failed, in words for the user.
  String? get error => _error;
  int? get clockSkewMinutes => _clockSkewMinutes;
  HostIntro? get intro => _intro;
  List<AgentInfo> get agents => _intro?.agents ?? const [];
  List<SessionSummary> get sessions => _sessions;

  Stream<SessionEvent> get updates => _updates.stream;
  Stream<PermissionEvent> get permissions => _permissions.stream;

  /// Fires each time the connection (re)comes up.
  Stream<void> get onOnline => _online.stream;

  /// Permission questions still open, oldest first.
  List<PermissionRequest> get openPermissions =>
      _askedPermissions.values.toList();

  SessionSummary? session(String sessionId) =>
      _sessions.where((s) => s.sessionId == sessionId).firstOrNull;

  /// The peer record changed (renamed); the connection is unaffected.
  void updateHost(PeerRecord host) {
    _host = host;
    notifyListeners();
  }

  Future<void> start() async {
    _stopped = false;
    final cached = await _cache?.loadSessions(key) ?? const [];
    if (_sessions.isEmpty && cached.isNotEmpty) {
      // Nothing is live until the computer says so.
      _sessions = [
        for (final s in cached) s.copyWith(working: false, running: false),
      ];
      notifyListeners();
    }
    unawaited(_open());
  }

  /// Retry right away (app came to the foreground, user pulled to refresh).
  void reconnectNow() {
    if (_stopped ||
        _status == HostStatus.online ||
        _status == HostStatus.unpaired) {
      return;
    }
    _retry?.cancel();
    _attempt = 0;
    unawaited(_open());
  }

  // ── requests ────────────────────────────────────────────────────────────

  /// A request to the computer; fails fast when it is not connected.
  Future<Json> call(
    String method, [
    Json params = const {},
    Duration? timeout,
  ]) {
    final peer = _peer;
    if (peer == null || _status != HostStatus.online) {
      return Future.error(RpcClosed(_offlineMessage));
    }
    final call = peer.call(method, params);
    return timeout == Duration.zero
        ? call
        : call.timeout(timeout ?? _callTimeout);
  }

  void notify(String method, [Json params = const {}]) =>
      _peer?.notify(method, params);

  /// Answers an open permission question; null [optionId] cancels it.
  void answerPermission(Object requestId, String? optionId) {
    _askedPermissions.remove(requestId);
    _pendingPermissions.remove(requestId)?.complete({
      'outcome': optionId == null
          ? {'outcome': 'cancelled'}
          : {'outcome': 'selected', 'optionId': optionId},
    });
  }

  Future<List<SessionSummary>> refreshSessions() async {
    final result = await call('session/list');
    _setSessions([
      for (final item in (result['sessions'] as List? ?? const []))
        if (item is Map) SessionSummary.fromJson(item.cast<String, dynamic>()),
    ]);
    return _sessions;
  }

  // ── connection ──────────────────────────────────────────────────────────

  String get _offlineMessage => _status == HostStatus.unpaired
      ? 'This phone is no longer paired with ${_host.label}.'
      : '${_host.label} is not connected.';

  Future<void> _open() async {
    if (_stopped || _socket != null) return;
    _setStatus(HostStatus.connecting);
    HostSocket socket;
    try {
      socket = await _connect(
        endpoint: _host.endpoint,
        hostKey: _host.remoteEpk,
        identity: await _identity(),
      ).timeout(const Duration(seconds: 12));
    } catch (error) {
      _error = 'Could not reach ${_host.label}.';
      _scheduleRetry();
      return;
    }
    if (_stopped) {
      await socket.close();
      return;
    }
    _socket = socket;
    final peer = JsonRpcPeer(
      write: socket.send,
      onRequest: _onRequest,
      onNotification: _onNotification,
    );
    _peer = peer;
    final subscription = socket.messages.listen(peer.receive);
    unawaited(
      socket.closed.then((closed) async {
        await subscription.cancel();
        _closed(socket, closed);
      }),
    );
    try {
      final intro = await peer
          .call('initialize', {
            'protocolVersion': protocolVersion,
            'clientCapabilities': {
              'fs': {'readTextFile': false, 'writeTextFile': false},
              'terminal': false,
            },
            'clientInfo': {'name': 'baya-android', 'title': 'Baya'},
          })
          .timeout(_callTimeout);
      _intro = HostIntro.fromJson(intro);
      _attempt = 0;
      _error = null;
      _clockSkewMinutes = null;
      _setStatus(HostStatus.online);
      await refreshSessions();
      if (!_online.isClosed) _online.add(null);
    } on RpcError catch (error) {
      if (error.code == RpcError.notPaired) {
        _becomeUnpaired();
      } else {
        _error = error.message;
      }
      await socket.close();
    } catch (_) {
      await socket.close();
    }
  }

  void _closed(HostSocket socket, SocketClosed closed) {
    if (_socket != socket) return;
    _socket = null;
    _peer?.close(RpcClosed(_offlineMessage));
    _peer = null;
    for (final id in _askedPermissions.keys.toList()) {
      _withdraw(id);
    }
    _setSessions([
      for (final s in _sessions) s.copyWith(working: false),
    ], save: false);
    if (closed.code == HostClose.unpaired) {
      _becomeUnpaired();
      return;
    }
    if (closed.clockSkewMinutes != null) {
      _clockSkewMinutes = closed.clockSkewMinutes;
      _error = "This phone's clock is ${closed.clockSkewMinutes} min off.";
    }
    if (_status != HostStatus.unpaired) _scheduleRetry();
  }

  void _becomeUnpaired() {
    _retry?.cancel();
    _error = 'This phone is no longer paired with ${_host.label}.';
    _setStatus(HostStatus.unpaired);
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _setStatus(HostStatus.offline);
    _retry?.cancel();
    final seconds = _retryDelays[_attempt.clamp(0, _retryDelays.length - 1)];
    _attempt++;
    _retry = Timer(Duration(seconds: seconds), () => unawaited(_open()));
  }

  void _setStatus(HostStatus status) {
    if (_status == status) return;
    _status = status;
    notifyListeners();
  }

  void _setSessions(List<SessionSummary> sessions, {bool save = true}) {
    sessions.sort(
      (a, b) =>
          (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
    );
    if (listEquals(sessions, _sessions)) return;
    _sessions = List.unmodifiable(sessions);
    notifyListeners();
    if (save) unawaited(_cache?.saveSessions(key, _sessions));
  }

  // ── from the computer ───────────────────────────────────────────────────

  Future<Object?> _onRequest(String method, Json params, Object id) {
    if (method != 'session/request_permission') {
      return Future.error(
        RpcError(RpcError.methodNotFound, 'Method not found: $method'),
      );
    }
    final request = PermissionRequest.fromJson(id, params);
    final answer = Completer<Json>();
    _pendingPermissions[id] = answer;
    _askedPermissions[id] = request;
    if (!_permissions.isClosed) {
      _permissions.add(PermissionEvent.asked(request));
    }
    notifyListeners();
    return answer.future;
  }

  void _onNotification(String method, Json params) {
    switch (method) {
      case 'session/update':
        final sessionId = params['sessionId'];
        final update = params['update'];
        if (sessionId is String && update is Map && !_updates.isClosed) {
          _updates.add(
            SessionEvent(
              sessionId,
              SessionUpdate.fromJson(update.cast<String, dynamic>()),
            ),
          );
        }
      case '_baya/session_changed':
        final raw = params['session'];
        if (raw is! Map) return;
        final changed = SessionSummary.fromJson(raw.cast<String, dynamic>());
        _setSessions([
          for (final s in _sessions)
            if (s.sessionId != changed.sessionId) s,
          changed,
        ]);
      case '_baya/session_removed':
        final id = params['sessionId'];
        _setSessions([
          for (final s in _sessions)
            if (s.sessionId != id) s,
        ]);
      case r'$/cancel_request':
        final id = params['requestId'];
        if (id is Object) _withdraw(id);
    }
  }

  void _withdraw(Object requestId) {
    final known = _askedPermissions.remove(requestId) != null;
    _pendingPermissions.remove(requestId);
    if (known && !_permissions.isClosed) {
      _permissions.add(PermissionEvent.withdrawn(requestId));
    }
    notifyListeners();
  }

  /// Stops for good (the computer was unpaired on this phone).
  Future<void> stop() async {
    _stopped = true;
    _retry?.cancel();
    final socket = _socket;
    _socket = null;
    _peer?.close(const RpcClosed('Disconnected.'));
    _peer = null;
    await socket?.close();
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_updates.close());
    unawaited(_permissions.close());
    unawaited(_online.close());
    super.dispose();
  }
}
