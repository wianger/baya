// ConnectionManager — lifecycle of the connections to paired computers.
//
// State machine:
//
//   [noPeer] → connect() → [connecting] → success → [online]
//                              ↓                         ↓
//                           failure               (WS close or 2 ping misses)
//                              ↓                         ↓
//                          [offline] ←── canRetry=false
//                          [retrying] ←── backoff 1→2→5→10→30s
//                              ↓
//                          connect() → [connecting] → …
//
// Ping: every 25 s. `_missedPings` increments per tick BEFORE sending the
// next ping; inbound traffic (handled by the channel listener) resets the
// counter back to 0. Two consecutive misses (~50s of silence) → retrying.
//
// Invariants that keep the loop from spinning while offline:
//
//  A) `_channelSub` is stored and cancelled on every transition, so an old
//     channel's `onDone` cannot leak into a retry storm.
//  B) `_retryAttempt` resets only when the channel receives real inbound
//     traffic, not when a socket merely opens, so a host that accepts and
//     then drops connections still backs off.
//  C) `_startPing` increments `_missedPings` per tick before sending the
//     ping. Inbound (`_watchChannel` listener) is the only path that
//     zeroes it; with the Pi offline two ticks elapse and we transition
//     to retrying without a leaky-bucket race.

import 'dart:async';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';

// ---------------------------------------------------------------------------
// Status model
// ---------------------------------------------------------------------------

sealed class ConnectionStatus {
  const ConnectionStatus();
}

class StatusNoPeer extends ConnectionStatus {
  const StatusNoPeer();
}

class StatusConnecting extends ConnectionStatus {
  const StatusConnecting();
}

class StatusOnline extends ConnectionStatus {
  final IChannel channel;
  const StatusOnline(this.channel);
}

class StatusRetrying extends ConnectionStatus {
  final Duration nextRetry;
  final int attempt; // 0-based
  const StatusRetrying({required this.nextRetry, required this.attempt});
}

class StatusOffline extends ConnectionStatus {
  final String reason;
  final bool canRetry;
  const StatusOffline({required this.reason, this.canRetry = true});
}

// ---------------------------------------------------------------------------
// Backoff sequence (seconds)
// ---------------------------------------------------------------------------

const _kBackoff = [1, 2, 5, 10, 30];

Duration _backoffFor(int attempt) =>
    Duration(seconds: _kBackoff[attempt.clamp(0, _kBackoff.length - 1)]);

// ---------------------------------------------------------------------------
// Factory typedef — injectable for tests
// ---------------------------------------------------------------------------

/// Called to establish a new connection for a given peer.
/// Returns an [IChannel] on success, throws on failure.
typedef ConnectionFactory = Future<IChannel> Function(
  PeerRecord peer,
  CancelToken cancel,
);

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// A status-only connection to a computer other than the active one. It
/// carries presence and room updates for the computers at its endpoint.
class _Watcher {
  _Watcher(this.via);
  PeerRecord via;
  List<String> epks = const [];
  IChannel? channel;
  final subs = <StreamSubscription<Object?>>[];
  CancelToken? connecting;
  Timer? retry;
  int attempt = 0;
  bool closed = false;
}

// ---------------------------------------------------------------------------
// ConnectionManager
// ---------------------------------------------------------------------------

class ConnectionManager extends Service {
  final ConnectionFactory _factory;
  final PairingStorage _storage;
  // Computers sharing an endpoint share a connection: the active computer's
  // endpoint is the main channel, every other endpoint gets a [_Watcher].
  final Map<String, _Watcher> _watchers = {};
  Map<String, String> _endpointByKey = const {};

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  // Presence: map per remote_epk + a broadcast stream the UI
  // listens to. The map is emitted whole on every change for simple
  // diffing on the consumer side.
  final Map<String, PresenceState> _presence = <String, PresenceState>{};
  final _presenceController =
      StreamController<Map<String, PresenceState>>.broadcast();
  // Rooms tracking. Keys are STANDARD base64 epks (matches
  // presence map). Each value is the canonical room list for that peer.
  // `_roomsByPeer` is the CANONICAL set (cached +
  // currently announced). `_liveRoomIds` tracks which roomIds are
  // alive RIGHT NOW (in the host's last push). Rooms in `_roomsByPeer`
  // but not in `_liveRoomIds` are "offline" (last-seen state).
  final Map<String, List<RoomInfo>> _roomsByPeer = <String, List<RoomInfo>>{};
  final Map<String, Set<String>> _liveRoomIds = <String, Set<String>>{};
  final _roomsController =
      StreamController<Map<String, List<RoomInfo>>>.broadcast();
  bool _roomsRestored = false;
  ConnectionStatus _status = const StatusNoPeer();
  PeerRecord? _activePeer;
  // Active room on the destination Pi. 'main' is the implicit
  // default and matches the per-cwd room a Pi opens.
  String _activeRoomId = 'main';

  Timer? _retryTimer;
  Timer? _pingTimer;
  // Watchdog timer that periodically checks for
  // "stuck offline" state (active peer set but status not online and
  // no retry / connect in flight). When detected, forces a fresh
  // _scheduleRetry. Belt-and-suspenders against any code path that
  // accidentally drops the retry chain.
  Timer? _watchdogTimer;
  CancelToken? _connectCancel;
  StreamSubscription<ServerMessage>? _channelSub;
  StreamSubscription<ControlInbound>? _controlSub;
  // List currently subscribed for presence (so reconnect can replay it).
  List<String> _subscribedEpks = const [];
  int _missedPings = 0;
  int _retryAttempt = 0;
  // Tracks the last-running connect token so the watchdog can tell
  // whether a connect is in flight (without poking at the live token).
  bool _connectInFlight = false;

  // Debounce timers — control frames are deduplicated in [_onControl],
  // but legitimate changes still arrive in tight bursts
  // (e.g. cwd switch publishes a new RoomAnnounced + RoomsSnapshot
  // back-to-back). Coalesce those into a single emit per window so
  // downstream listeners (HomeViewModel → Flutter widget rebuilds)
  // see one update instead of three.
  Timer? _presenceEmitTimer;
  Timer? _roomsEmitTimer;
  final Duration _emitDebounce;
  final Duration _connectTimeout;
  final Duration _channelCloseTimeout;

  ConnectionManager({
    required ConnectionFactory factory,
    required PairingStorage storage,
    Duration emitDebounce = const Duration(milliseconds: 50),
    Duration connectTimeout = const Duration(seconds: 10),
    Duration channelCloseTimeout = const Duration(seconds: 2),
  }) : // Public parameter names are part of the constructor API.
       // ignore: prefer_initializing_formals
       _factory = factory,
       // ignore: prefer_initializing_formals
       _storage = storage,
       // ignore: prefer_initializing_formals
       _emitDebounce = emitDebounce,
       // ignore: prefer_initializing_formals
       _connectTimeout = connectTimeout,
       // ignore: prefer_initializing_formals
       _channelCloseTimeout = channelCloseTimeout {
    _startWatchdog();
  }

  /// Periodically checks for stuck offline state
  /// and forces a reconnect attempt. Runs every 15s. Cheap; only
  /// fires the actual `_scheduleRetry` when the conditions match.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final peer = _activePeer;
      if (peer == null) return;
      if (_status is StatusOnline) return;
      if (_connectInFlight) return;
      if (_retryTimer != null) return;
      // We SHOULD be reconnecting but nothing's scheduled and no
      // attempt is in flight. Kick the retry chain.
      _scheduleRetry(peer);
    });
  }

  ConnectionStatus get status => _status;
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  IChannel? get channel =>
      _status is StatusOnline ? (_status as StatusOnline).channel : null;

  /// The peer this manager is currently driving (online, connecting, or
  /// retrying). Null when there is no active peer (NoPeer / Offline-noRetry
  /// / fresh after disconnect()).
  PeerRecord? get activePeer => _activePeer;

  // ---- Presence -------------------------------------------------

  /// Stream of full presence-map snapshots. Subscribers should treat each
  /// event as the canonical state for all keys present in the map.
  Stream<Map<String, PresenceState>> get presenceStream =>
      _presenceController.stream;

  /// Current presence for an epk (or [PresenceUnknown] if never observed).
  /// Accepts either url-safe (PairingStorage) or standard base64; the map
  /// itself is keyed in standard form (see [_onControl]).
  PresenceState presenceFor(String epk) =>
      _presence[toStandardB64(epk)] ?? const PresenceUnknown();

  /// Full snapshot copy of the current presence map. Keys are standard
  /// base64 — UI code that compares against `PeerRecord.remoteEpk`
  /// (url-safe) should also call [toStandardB64] before lookup. The Home
  /// tile / chat resolver do this via [presenceFor].
  Map<String, PresenceState> get presenceSnapshot =>
      Map.unmodifiable(_presence);

  // ---- Rooms -----------------------------------------------------

  /// Stream of full room-map snapshots. Each event is the canonical
  /// list of rooms per peer (standard-base64 keys).
  Stream<Map<String, List<RoomInfo>>> get roomsStream =>
      _roomsController.stream;

  Map<String, List<RoomInfo>> get roomsSnapshot => _roomsSnapshot();

  /// Rooms for a single peer (or empty list if none known yet). Accepts
  /// url-safe or standard base64.
  List<RoomInfo> roomsFor(String epk) =>
      List.unmodifiable(_roomsByPeer[toStandardB64(epk)] ?? const []);

  /// Active destination room (the Pi-side room id). 'main' = default.
  String get activeRoomId => _activeRoomId;

  /// Switch the destination room WITHOUT closing the current WS. The
  /// outer envelope's `room` field on subsequent sends will carry this
  /// value. Use when the user taps a different Pi cwd on Home.
  void switchRoom(String roomId) {
    if (roomId == _activeRoomId) {
      return;
    }
    _activeRoomId = roomId;
    final active = _activePeer;
    if (active != null) {
      _activePeer = active.copyWith(roomId: roomId);
    }
    // Push down to the underlying WS transport so outbound envelopes
    // get the right `room` value.
    final cur = _status;
    if (cur is StatusOnline) {
      _propagateActiveRoom(roomId, cur.channel);
    }
    // Re-emit the rooms snapshot so derived per-active-room state
    // (ActionsRepository.activeRoomMeta → the Quick Actions sheet's current
    // model/thinking) recomputes for the NEW room. Switching cwd-rooms on the
    // same Mac doesn't change status/rooms otherwise, so without this the
    // sheet kept showing the previous chat's model.
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  void _propagateActiveRoom(String roomId, IChannel link) {
    // A hook into the transport, not a frame. PlainPeerChannel exposes
    // `setActiveRoom` via a hidden interface; for typing simplicity we
    // try the dynamic call. If the transport doesn't support it, we
    // silently skip and the default 'main' room is used.
    try {
      (link as dynamic).setActiveRoom(roomId);
    } catch (_) {
      // Tests / non-WS transports — fine to ignore.
    }
  }

  /// Subscribe (or re-subscribe) to presence AND room updates for [epks]
  /// (`peer_online` / `peer_offline` and `room_announced` / `room_ended` /
  /// `rooms`), on the active connection and the watchers. Idempotent;
  /// replayed on reconnect via [_replaySubscriptions].
  ///
  /// Every epk on the wire is base64 STANDARD. Callers may pass url-safe
  /// (PairingStorage default); we normalise once here, and the internal
  /// cache (`_subscribedEpks`, `_presence` keys) stays standard too.
  void subscribeToPeers(List<String> epks) {
    final standard = epks.map(toStandardB64).toList();
    _subscribedEpks = standard;
    unawaited(_syncWatchers());
    final link = _controlLink;
    if (link == null) {
      return;
    }
    _subscribe(link, _activeEpks());
  }

  /// Subscribed computers reached through the active connection.
  List<String> _activeEpks() {
    final active = _activePeer?.endpoint;
    return [
      for (final key in _subscribedEpks)
        if (_endpointByKey[key] == null || _endpointByKey[key] == active) key,
    ];
  }

  void _subscribe(IControlLink link, List<String> epks) {
    link.sendControl(subscribePresenceFrame(epks));
    link.sendControl(subscribeRoomsFrame(epks));
    if (epks.isNotEmpty) {
      link.sendControl(presenceCheckFrame(epks));
      link.sendControl(roomsCheckFrame(epks));
    }
  }

  /// One-shot snapshot request without changing the subscription.
  void refreshPresence([List<String>? epks]) {
    final link = _controlLink;
    if (link == null) return;
    final list = (epks ?? _activeEpks()).map(toStandardB64).toList();
    if (list.isEmpty) return;
    link.sendControl(presenceCheckFrame(list));
  }

  // ---- Other addresses ------------------------------------------------

  /// Opens a watcher for every address other than the active one and closes
  /// the ones no longer needed. Without an active computer there are none.
  Future<void> _syncWatchers() async {
    final List<PeerRecord> peers;
    try {
      peers = await _storage.listPeers();
    } catch (_) {
      return; // Unreadable storage: keep the current watchers until next time.
    }
    if (_statusController.isClosed) return;
    final groups = <String, List<PeerRecord>>{};
    final byKey = <String, String>{};
    for (final peer in peers) {
      final endpoint = peer.endpoint;
      byKey[toStandardB64(peer.remoteEpk)] = endpoint;
      (groups[endpoint] ??= []).add(peer);
    }
    final routingChanged = !_mapEquals(byKey, _endpointByKey);
    _endpointByKey = byKey;
    final active = _activePeer;
    if (active == null) {
      groups.clear();
    } else {
      groups.remove(active.endpoint);
    }
    for (final endpoint in _watchers.keys.toList()) {
      if (!groups.containsKey(endpoint)) {
        _closeWatcher(_watchers.remove(endpoint)!);
      }
    }
    groups.forEach((endpoint, members) {
      final watcher = _watchers[endpoint] ??= _Watcher(members.first);
      watcher.via = members.first;
      final epks = [for (final p in members) toStandardB64(p.remoteEpk)];
      final changed = !_listEquals(epks, watcher.epks);
      watcher.epks = epks;
      final channel = watcher.channel;
      if (channel != null) {
        if (changed && channel is IControlLink) {
          _subscribe(channel as IControlLink, epks);
        }
      } else if (watcher.connecting == null && watcher.retry == null) {
        unawaited(_openWatcher(watcher));
      }
    });
    if (routingChanged) _replaySubscriptions();
  }

  Future<void> _openWatcher(_Watcher watcher) async {
    final token = CancelToken();
    watcher.connecting = token;
    try {
      final channel = await _openWithTimeout(watcher.via, token);
      if (token.isCancelled || watcher.closed || channel is! IControlLink) {
        await _closeChannel(channel);
        return;
      }
      final link = channel as IControlLink;
      watcher.channel = channel;
      void lost([Object? _]) => _watcherLost(watcher, channel);
      watcher.subs
        ..add(
          link.controlFrames.listen(_onControl, onError: lost, onDone: lost),
        )
        ..add(
          channel.serverMessages.listen(
            (_) => watcher.attempt = 0,
            onError: lost,
            onDone: lost,
          ),
        );
      _subscribe(link, watcher.epks);
      _scheduleRoomsEmit();
    } catch (_) {
      if (!token.isCancelled && !watcher.closed) _retryWatcher(watcher);
    } finally {
      if (identical(watcher.connecting, token)) watcher.connecting = null;
    }
  }

  /// The connection to a watched address dropped: everything behind it is
  /// offline until it comes back.
  void _watcherLost(_Watcher watcher, IChannel channel) {
    if (!identical(watcher.channel, channel)) return;
    _dropWatcherChannel(watcher);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final key in watcher.epks) {
      _presence[key] = PresenceOffline(sinceTs: now);
      _liveRoomIds.remove(key);
    }
    _schedulePresenceEmit();
    _scheduleRoomsEmit();
    if (!watcher.closed) _retryWatcher(watcher);
  }

  void _retryWatcher(_Watcher watcher) {
    watcher.retry?.cancel();
    watcher.retry = Timer(_backoffFor(watcher.attempt++), () {
      watcher.retry = null;
      if (!watcher.closed) unawaited(_openWatcher(watcher));
    });
  }

  void _dropWatcherChannel(_Watcher watcher) {
    for (final sub in watcher.subs) {
      unawaited(sub.cancel());
    }
    watcher.subs.clear();
    final channel = watcher.channel;
    watcher.channel = null;
    if (channel != null) unawaited(_closeChannel(channel));
  }

  void _closeWatcher(_Watcher watcher) {
    watcher.closed = true;
    watcher.connecting?.cancel();
    watcher.retry?.cancel();
    watcher.retry = null;
    _dropWatcherChannel(watcher);
  }

  /// Whether fresh state for [key] is arriving: through the active channel
  /// or through the watcher for its address.
  bool _reachable(String key) {
    final endpoint = _endpointByKey[key];
    final active = _activePeer;
    if (endpoint == null || active == null || endpoint == active.endpoint) {
      return _status is StatusOnline;
    }
    return _watchers[endpoint]?.channel != null;
  }

  /// Current online channel cast to its control side, when supported.
  IControlLink? get _controlLink {
    final s = _status;
    if (s is! StatusOnline) return null;
    final ch = s.channel;
    return ch is IControlLink ? ch as IControlLink : null;
  }

  /// Open the WS and start driving a peer. Accepts an optional
  /// [preferredEpk] so the caller can express the user's
  /// authoritative choice — typically `Preferences.selectedPeerEpk`.
  /// When the preferred epk is not in storage (or omitted), falls back
  /// to `peers.first`.
  ///
  /// No-op when there is already an active peer (online, connecting, or
  /// retrying). In that case we still re-subscribe presence with the
  /// full peer list, since the storage may have changed.
  Future<void> boot({String? preferredEpk}) async {
    // Restore cached rooms from disk FIRST so Home tiles render with
    // last-known state before the host pushes a fresh snapshot.
    // Idempotent so reentrant boots are harmless.
    await _restoreCachedRooms();
    if (_activePeer != null) {
      final peers = await _storage.listPeers();
      subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
      return;
    }
    if (_status is StatusOnline) return;
    final peers = await _storage.listPeers();
    if (peers.isEmpty) {
      _emit(const StatusNoPeer());
      return;
    }
    // Through `subscribeToPeers` so the epks are stored normalised; the
    // frames go out via `_replaySubscriptions` once `_connect` succeeds.
    subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    PeerRecord target;
    if (preferredEpk != null) {
      target = peers.firstWhere(
        (p) => p.remoteEpk == preferredEpk,
        orElse: () => peers.first,
      );
    } else {
      target = peers.first;
    }
    await _connect(target);
  }

  // Connect to a specific peer (used after fresh pairing).
  Future<void> connectTo(PeerRecord peer) => _connect(peer);

  /// Idempotent switch to another paired peer. If `peer` already matches
  /// [activePeer] AND we are Online, no-op. Otherwise tears down the
  /// current channel WITHOUT emitting a transient `StatusNoPeer` and
  /// starts a fresh connection — the visible transition becomes
  /// `Online → Connecting → Online`, never landing on NoPeer.
  Future<void> switchTo(PeerRecord peer) async {
    final fromEpk = _activePeer?.remoteEpk;
    if (fromEpk == peer.remoteEpk && _status is StatusOnline) {
      return;
    }
    await _teardownActive(emitNoPeer: false);
    await _connect(peer);
  }

  // Adopt a channel that was established by an external flow (e.g. the
  // pairing handshake). Skips the factory entirely — the channel is already
  // connected and ready for use.
  void adopt(IChannel channel, PeerRecord peer) {
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    if (_status is StatusOnline) {
      final old = (_status as StatusOnline).channel;
      // ignore: unawaited_futures
      Future(() async {
        try {
          await old.close();
        } catch (_) {}
      });
    }
    _retryAttempt = 0;
    _missedPings = 0;
    _activeRoomId = peer.roomId;
    _activePeer = peer;
    _emit(StatusOnline(channel));
    _startPing(peer, channel);
    _watchChannel(peer, channel);
    _watchControl(channel);
    _replaySubscriptions();
    unawaited(_syncWatchers());
  }

  // Permanently disconnect and go to NoPeer.
  Future<void> disconnect() => _teardownActive(emitNoPeer: true);

  /// Shared implementation between [disconnect] and [switchTo]. When
  /// [emitNoPeer] is false (switch path), the `_status` is left as-is so
  /// a subsequent `_connect` can emit `StatusConnecting` directly,
  /// avoiding the visible Online → NoPeer → Connecting flicker that used
  /// to trip up `ChatViewModel._bootstrap`.
  Future<void> _teardownActive({required bool emitNoPeer}) async {
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    if (_status is StatusOnline) {
      await _closeChannel((_status as StatusOnline).channel);
    }
    if (emitNoPeer) {
      _activePeer = null;
      _emit(const StatusNoPeer());
      unawaited(_syncWatchers());
    }
    // When emitNoPeer is false, `_connect` will immediately overwrite
    // `_activePeer` and emit `StatusConnecting`, so we deliberately leave
    // the state alone here.
  }

  @override
  void dispose() {
    _cancelRetry();
    _cancelPing();
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _presenceEmitTimer?.cancel();
    _presenceEmitTimer = null;
    _roomsEmitTimer?.cancel();
    _roomsEmitTimer = null;
    _connectCancel?.cancel();
    _connectCancel = null;
    _connectInFlight = false;
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;
    for (final watcher in _watchers.values) {
      _closeWatcher(watcher);
    }
    _watchers.clear();
    _statusController.close();
    _presenceController.close();
  }

  // ---------------------------------------------------------------------------

  Future<void> _connect(PeerRecord peer) async {
    _cancelRetry();
    _cancelPing();
    _connectCancel?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _controlSub?.cancel();
    _controlSub = null;

    final token = CancelToken();
    _connectCancel = token;
    _connectInFlight = true;
    // Set the destination room from the persisted PeerRecord BEFORE
    // emitting StatusOnline so the very first send goes to the right room.
    //
    // Same-peer reconnect (WS retry after backgrounding): the `peer`
    // argument is often a stale capture from `_watchChannel` while
    // `switchRoom` already moved `_activeRoomId` for the cwd the user
    // is viewing. Trust the live selection — never clobber it from a
    // lagging peer.roomId (fixes header=cwd-A, messages/sync=cwd-B).
    final samePeer = _activePeer?.remoteEpk == peer.remoteEpk;
    if (samePeer) {
      _activePeer = peer.copyWith(roomId: _activeRoomId);
    } else {
      _activePeer = peer;
      final boundRoom = peer.roomId;
      if (boundRoom != _activeRoomId) {
        _activeRoomId = boundRoom;
      }
    }
    _emit(const StatusConnecting());
    unawaited(_syncWatchers());

    try {
      final ch = await _openWithTimeout(peer, token);
      if (token.isCancelled) {
        await _closeChannel(ch);
        return;
      }
      _missedPings = 0;
      // Push down the active room to the WS so the outer envelope
      // carries it from frame 1 (factory creates a fresh WsTransport
      // every reconnect — default _activeRoom='main' unless we set).
      _propagateActiveRoom(_activeRoomId, ch);
      _emit(StatusOnline(ch));
      _startPing(peer, ch);
      _watchChannel(peer, ch);
      _watchControl(ch);
      _replaySubscriptions();
    } catch (e) {
      if (!token.isCancelled) _scheduleRetry(peer);
    } finally {
      // Only clear the flight flag if THIS call is still the active
      // attempt — a newer _connect may have superseded us.
      if (identical(_connectCancel, token)) _connectInFlight = false;
    }
  }

  Future<IChannel> _openWithTimeout(PeerRecord peer, CancelToken token) async {
    final attempt = _factory(peer, token);
    var timedOut = false;
    try {
      return await attempt.timeout(
        _connectTimeout,
        onTimeout: () {
          timedOut = true;
          throw TimeoutException(
            'Connection to ${peer.remoteEpk} timed out.',
            _connectTimeout,
          );
        },
      );
    } on TimeoutException {
      if (timedOut) {
        // Future.timeout stops waiting but cannot cancel the factory. Close a
        // channel if the factory eventually completes after the deadline.
        unawaited(
          attempt.then<void>(
            (channel) => _closeChannel(channel),
            onError: (Object _, StackTrace _) {},
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> _closeChannel(IChannel channel) async {
    try {
      await channel.close().timeout(_channelCloseTimeout);
    } on TimeoutException {
      // A broken transport must not prevent switching to another computer.
    } catch (_) {
      // A failed close still means the old connection is no longer selected.
    }
  }

  void _watchControl(IChannel ch) {
    _controlSub?.cancel();
    if (ch is! IControlLink) {
      _controlSub = null;
      return;
    }
    _controlSub = (ch as IControlLink).controlFrames.listen(_onControl);
  }

  void _onControl(ControlInbound c) {
    // Epks are normalised to standard base64 on insert so lookups via
    // `presenceFor` (which coerces) round-trip.
    //
    // Dedup: the host repeats `peer_online`, `presence` and `rooms` on
    // every (re)subscribe. Each case below only flips its `*Dirty` flag if
    // the payload changes our cached view, so Home does not rebuild for
    // nothing.
    var presenceDirty = false;
    var roomsDirty = false;
    switch (c) {
      case PeerOnline(:final peer):
        final key = toStandardB64(peer);
        final prev = _presence[key];
        const next = PresenceOnline();
        if (!_presenceEquals(prev, next)) {
          _presence[key] = next;
          presenceDirty = true;
        }
      case PeerOffline(:final peer, :final sinceTs):
        final key = toStandardB64(peer);
        final prev = _presence[key];
        final next = PresenceOffline(sinceTs: sinceTs);
        if (!_presenceEquals(prev, next)) {
          _presence[key] = next;
          presenceDirty = true;
        }
      case PresenceSnapshot(:final states):
        for (final s in states) {
          final key = toStandardB64(s.peer);
          final prev = _presence[key];
          final next = s.online
              ? PresenceOnline(sinceTs: s.sinceTs)
              : PresenceOffline(sinceTs: s.sinceTs);
          if (!_presenceEquals(prev, next)) {
            _presence[key] = next;
            presenceDirty = true;
          }
        }
      case RoomAnnounced(:final peer, :final room):
        final key = toStandardB64(peer);
        final list = _roomsByPeer[key] ?? <RoomInfo>[];
        // A local rename survives; everything else comes from the host.
        final existingIdx = list.indexWhere((r) => r.roomId == room.roomId);
        final next = existingIdx >= 0
            ? room.copyWith(name: list[existingIdx].name)
            : room;
        final liveAlready = _liveRoomIds[key]?.contains(room.roomId) ?? false;
        if (existingIdx >= 0 && list[existingIdx] == next && liveAlready) {
          break;
        }
        list.removeWhere((r) => r.roomId == room.roomId);
        list.add(next);
        _roomsByPeer[key] = list;
        (_liveRoomIds[key] ??= <String>{}).add(room.roomId);
        roomsDirty = true;
        // ignore: unawaited_futures
        _persistRoomsForPeer(key);
      case RoomEnded(:final peer, :final roomId):
        final key = toStandardB64(peer);
        // Mark the room offline but KEEP it in the cached set so the
        // tile stays in Home (now grey). Removing from _liveRoomIds
        // is enough.
        final removed = _liveRoomIds[key]?.remove(roomId) ?? false;
        if (_liveRoomIds[key]?.isEmpty ?? false) {
          _liveRoomIds.remove(key);
        }
        if (removed) roomsDirty = true;
      case RoomMetaUpdated(
        :final peer,
        :final roomId,
        :final model,
        :final thinking,
        :final working,
      ):
        final key = toStandardB64(peer);
        final list = _roomsByPeer[key];
        if (list == null) break;
        final idx = list.indexWhere((r) => r.roomId == roomId);
        if (idx < 0) break;
        final next = list[idx].copyWith(
          model: model,
          thinking: thinking,
          working: working,
        );
        if (next == list[idx]) break;
        list[idx] = next;
        roomsDirty = true;
        // ignore: unawaited_futures
        _persistRoomsForPeer(key);
      case RoomsSnapshot(:final peer, :final rooms):
        final key = toStandardB64(peer);
        // The snapshot is authoritative except for a local rename; rooms
        // it lacks stay cached (offline) until deleted.
        final existing = _roomsByPeer[key] ?? <RoomInfo>[];
        final byId = {for (final r in existing) r.roomId: r};
        for (final r in rooms) {
          final cached = byId[r.roomId];
          byId[r.roomId] = cached == null ? r : r.copyWith(name: cached.name);
        }
        final newList = byId.values.toList();
        final newLive = rooms.map((r) => r.roomId).toSet();
        final liveChanged = !_setEquals(
          newLive,
          _liveRoomIds[key] ?? const <String>{},
        );
        final listChanged = !_roomListEquals(newList, existing);
        if (!liveChanged && !listChanged) {
          break; // identical to what we have
        }
        _roomsByPeer[key] = newList;
        _liveRoomIds[key] = newLive;
        roomsDirty = true;
        // ignore: unawaited_futures
        _persistRoomsForPeer(key);
    }
    if (presenceDirty) _schedulePresenceEmit();
    if (roomsDirty) _scheduleRoomsEmit();
  }

  /// Coalesce presence emits within `_emitDebounce`. Each call resets
  /// the timer; the snapshot sent at fire time is whatever `_presence`
  /// looks like then (always the latest view).
  void _schedulePresenceEmit() {
    _presenceEmitTimer?.cancel();
    _presenceEmitTimer = Timer(_emitDebounce, () {
      _presenceEmitTimer = null;
      if (_presenceController.isClosed) return;
      _presenceController.add(Map.unmodifiable(_presence));
    });
  }

  /// Same shape as [_schedulePresenceEmit] but for the rooms stream.
  void _scheduleRoomsEmit() {
    _roomsEmitTimer?.cancel();
    _roomsEmitTimer = Timer(_emitDebounce, () {
      _roomsEmitTimer = null;
      if (_roomsController.isClosed) return;
      _roomsController.add(_roomsSnapshot());
    });
  }

  /// Value-equality helper for [PresenceState] — the sealed classes
  /// don't define their own `==`, and identity equality misfires
  /// because we construct fresh `PresenceOnline(...)` / `PresenceOffline(...)`
  /// objects on each control frame.
  bool _presenceEquals(PresenceState? a, PresenceState? b) {
    if (a == null) return b == null;
    if (b == null) return false;
    if (a.runtimeType != b.runtimeType) return false;
    if (a is PresenceOnline && b is PresenceOnline) {
      return a.sinceTs == b.sinceTs;
    }
    if (a is PresenceOffline && b is PresenceOffline) {
      return a.sinceTs == b.sinceTs;
    }
    // PresenceUnknown has no fields — same type ⇒ equal.
    return true;
  }

  /// `Set<String>` deep-equality (Dart sets don't have value-equality
  /// by default).
  bool _setEquals(Set<String> a, Set<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final x in a) {
      if (!b.contains(x)) return false;
    }
    return true;
  }

  /// `List<RoomInfo>` order-insensitive equality keyed by `roomId`.
  /// `RoomInfo` already defines value `==`.
  bool _roomListEquals(List<RoomInfo> a, List<RoomInfo> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    final byIdB = {for (final r in b) r.roomId: r};
    for (final r in a) {
      if (byIdB[r.roomId] != r) return false;
    }
    return true;
  }

  Map<String, List<RoomInfo>> _roomsSnapshot() => Map.unmodifiable(
    _roomsByPeer.map((k, v) => MapEntry(k, List<RoomInfo>.unmodifiable(v))),
  );

  /// Returns `true` if `roomId` is currently announced live for the
  /// peer (the host's last `room_announced` / `rooms` push included it).
  /// Cached rooms not in the live set return `false`.
  ///
  /// Gated on the connection that carries this peer: while it is down we
  /// have no fresh signal, so every room behind it reports offline. On
  /// reconnect the host pushes its rooms again and the live set refills.
  bool isRoomLive(String epk, String roomId) {
    final key = toStandardB64(epk);
    if (!_reachable(key)) return false;
    final live = _liveRoomIds[key];
    return live != null && live.contains(roomId);
  }

  /// `true` when the host's last room update for `(epk, roomId)` carried
  /// `working: true` (an in-flight agent turn). The host pushes it for
  /// every room, so it drives the Home dot on non-active sessions too.
  ///
  /// Gated like [isRoomLive]: without a connection we report not-working.
  bool isRoomWorking(String epk, String roomId) {
    final key = toStandardB64(epk);
    if (!_reachable(key)) return false;
    final list = _roomsByPeer[key];
    if (list == null) return false;
    for (final r in list) {
      if (r.roomId == roomId) return r.working;
    }
    return false;
  }

  /// App-side correction for the connected room's working flag.
  ///
  /// The host's room updates remain the source for other rooms, but the active channel
  /// also sees the actual `user_input` / `agent_done` frames. Use that local
  /// observation as a backstop so a missed or delayed `meta.working=false`
  /// broadcast cannot leave the active chat/Home tile stuck as working.
  void markRoomWorking(String epk, String roomId, bool working) {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list == null) return;
    final idx = list.indexWhere((r) => r.roomId == roomId);
    if (idx < 0 || list[idx].working == working) return;
    list[idx] = list[idx].copyWith(working: working);
    _scheduleRoomsEmit();
    // ignore: unawaited_futures
    _persistRoomsForPeer(key);
  }

  /// Hydrate `_roomsByPeer` from disk on boot so Home tiles persist across
  /// cold starts before the host pushes a fresh snapshot. Idempotent.
  Future<void> _restoreCachedRooms() async {
    if (_roomsRestored) return;
    _roomsRestored = true;
    final peers = await _storage.listPeers();
    for (final p in peers) {
      final cached = await _storage.loadRooms(p.remoteEpk);
      if (cached.isEmpty) continue;
      final key = toStandardB64(p.remoteEpk);
      _roomsByPeer[key] = cached
          .map(
            (c) => RoomInfo(
              roomId: c.roomId,
              agent: c.agent,
              name: c.localName ?? c.name,
              cwd: c.cwd,
              startedAt: c.startedAt,
              model: c.model,
            ),
          )
          .toList();
      // Note: nothing in _liveRoomIds yet — those rooms are "offline"
      // until the host announces them again.
    }
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  Future<void> _persistRoomsForPeer(String peerKey) async {
    final peers = await _storage.listPeers();
    PeerRecord? match;
    for (final p in peers) {
      if (toStandardB64(p.remoteEpk) == peerKey) {
        match = p;
        break;
      }
    }
    if (match == null) return;
    final list = _roomsByPeer[peerKey] ?? const <RoomInfo>[];
    // Read the current on-disk localNames so we don't drop the user's
    // long-press rename when we re-persist in response to a wire
    // metadata refresh.
    final existing = await _storage.loadRooms(match.remoteEpk);
    final localById = {
      for (final p in existing)
        if (p.localName != null && p.localName!.isNotEmpty)
          p.roomId: p.localName!,
    };
    final persisted = list
        .map(
          (r) => PersistedRoom(
            roomId: r.roomId,
            agent: r.agent,
            name: r.name,
            cwd: r.cwd,
            startedAt: r.startedAt,
            localName: localById[r.roomId],
            model: r.model,
          ),
        )
        .toList();
    await _storage.saveRooms(match.remoteEpk, persisted);
  }

  /// Long-press menu support. Override the
  /// display name of a single room locally (Pi never sees this).
  /// Reflects immediately in the rooms snapshot.
  Future<void> setRoomLocalName(String epk, String roomId, String? name) async {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list == null) return;
    final idx = list.indexWhere((r) => r.roomId == roomId);
    if (idx < 0) return;
    final old = list[idx];
    // Use copyWith so EVERY field (model, cwd, startedAt, …) is
    // preserved. The previous explicit constructor call dropped
    // `model`, which made the tile subtitle fall back to
    // "Last Paired: …" right after a rename — bug.
    list[idx] = old.copyWith(
      name: (name != null && name.isNotEmpty) ? name : old.name,
    );
    // Persist with localName so it survives cold start.
    final cached = await _storage.loadRooms(epk);
    final updated = cached
        .map((c) => c.roomId == roomId ? c.copyWith(localName: name) : c)
        .toList();
    await _storage.saveRooms(epk, updated);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  /// Delete a cached room locally. Only safe when
  /// the room is offline (not live); UI gates this.
  Future<void> deleteCachedRoom(String epk, String roomId) async {
    final key = toStandardB64(epk);
    final list = _roomsByPeer[key];
    if (list != null) {
      list.removeWhere((r) => r.roomId == roomId);
      if (list.isEmpty) _roomsByPeer.remove(key);
    }
    final cached = await _storage.loadRooms(epk);
    final pruned = cached.where((c) => c.roomId != roomId).toList();
    await _storage.saveRooms(epk, pruned);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  /// On (re)connect, re-send the presence and room subscriptions for the
  /// computers this connection carries.
  void _replaySubscriptions() {
    if (_subscribedEpks.isEmpty) return;
    final link = _controlLink;
    if (link == null) return;
    _subscribe(link, _activeEpks());
  }

  void _watchChannel(PeerRecord peer, IChannel ch) {
    _channelSub?.cancel();
    _channelSub = ch.serverMessages.listen(
      (msg) {
        // Real inbound — the Pi is alive and reachable. Safe to reset
        // both the ping miss counter and the retry backoff.
        _missedPings = 0;
        _retryAttempt = 0;
      },
      onError: (_) => _onChannelLost(peer, ch),
      onDone: () => _onChannelLost(peer, ch),
    );
  }

  void _onChannelLost(PeerRecord peer, IChannel ch) {
    if (_status is! StatusOnline) return;
    final cur = (_status as StatusOnline).channel;
    if (!identical(cur, ch)) {
      // Stale: this onDone came from a channel we already replaced.
      return;
    }
    _cancelPing();
    _scheduleRetry(peer);
  }

  void _scheduleRetry(PeerRecord peer) {
    final delay = _backoffFor(_retryAttempt);
    _emit(StatusRetrying(nextRetry: delay, attempt: _retryAttempt));
    // Cancel any previous timer before scheduling — prevents the
    // "two timers firing back-to-back" footgun.
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _retryAttempt++;
      _connect(peer);
    });
  }

  void _startPing(PeerRecord peer, IChannel ch) {
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      if (_status is! StatusOnline) return;
      // Agent liveness, not socket liveness: the socket is kept alive by
      // WebSocket ping frames (IOWebSocketChannel.pingInterval). Missed
      // protocol Pongs mark the active room offline locally; the socket
      // stays up for presence and other rooms. A real socket failure
      // surfaces via the catch below or the channel listener's
      // onError / onDone, both of which trigger `_onChannelLost`.
      _missedPings++;
      if (_missedPings == 3) {
        _markActiveRoomOffline();
        // No `return` — keep firing pings. When Pi comes back, the
        // inbound Pong (or any other frame) resets _missedPings via
        // _watchChannel, and `room_announced` repopulates
        // _liveRoomIds → tile + AppBar flip back to green
        // automatically.
      }
      try {
        final id = _newId();
        await ch.send(Ping(id: id));
      } catch (e) {
        _cancelPing();
        _onChannelLost(peer, ch);
      }
    });
  }

  /// When the agent stops answering protocol Pings, mark its room offline
  /// locally so the UI reflects it. The socket stays up.
  void _markActiveRoomOffline() {
    final activeEpk = _activePeer?.remoteEpk;
    if (activeEpk == null) return;
    final key = toStandardB64(activeEpk);
    final live = _liveRoomIds[key];
    if (live == null || !live.contains(_activeRoomId)) return;
    live.remove(_activeRoomId);
    if (live.isEmpty) _liveRoomIds.remove(key);
    if (!_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _cancelPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _missedPings = 0;
  }

  void _emit(ConnectionStatus s) {
    // When the connection-status flips ON or OFF
    // StatusOnline, every room's "live" answer changes too (see
    // `isRoomLive` gate). Re-emit the rooms snapshot so subscribers
    // (Home, Chat AppBar) re-evaluate dot color immediately, without
    // waiting for the host's next push.
    final wasOnline = _status is StatusOnline;
    final nowOnline = s is StatusOnline;
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
    if (wasOnline != nowOnline && !_roomsController.isClosed) {
      _roomsController.add(_roomsSnapshot());
    }
  }

  static bool _listEquals(List<String> a, List<String> b) =>
      a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  static int _idCounter = 0;
  static String _newId() => 'ping_${++_idCounter}';
}
