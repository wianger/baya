import 'dart:async';

import 'package:app/l10n/l10n.dart';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/sync/sync_service.dart';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/states/home_state.dart';

/// HomeViewModel — passive list of paired peers + live presence dots
/// + rooms discovered on each peer. A single tile per
/// (peer, room).
///
/// The WS connection is owned by [ConnectionManager] from app boot.
/// Home only:
///   - reads the peer list from storage
///   - watches `presenceStream` + `roomsStream` to render dots / rooms
///     in real time
///   - writes [Preferences.selectedRoom] when the user taps a tile so
///     `/chat` knows which (peer, room) to address
class HomeViewModel extends ViewModel<HomeState> {
  final PairingStorage _storage;
  final SyncService? _sync;
  final Preferences _prefs;
  final ConnectionManager _conn;
  final IActionsRepository? _actions;
  StreamSubscription<Map<String, PresenceState>>? _presenceSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  bool _connected = false;
  bool _disposed = false;
  bool _inventoryRefreshInFlight = false;
  DateTime? _lastInventoryRefresh;

  HomeViewModel(
    this._storage,
    this._prefs,
    this._conn, [
    this._sync,
    this._actions,
  ]) : super(const HomeLoading()) {
    _connected = _conn.status is StatusOnline;
    _load();
    _presenceSub = _conn.presenceStream.listen(_onPresence);
    _roomsSub = _conn.roomsStream.listen(_onRooms);
    _statusSub = _conn.statusStream.listen(_onStatus);
    // Settings (rename / revoke) and pairing flow both write through
    // PairingStorage; listening here keeps Home in sync without manual
    // notifications between screens.
    _storage.addListener(_onStorageChanged);
    _prefs.addListener(_onPreferencesChanged);
  }

  void _onPreferencesChanged() {
    if (_disposed) return;
    final before = state;
    _onRooms(_conn.roomsSnapshot);
    if (identical(before, state)) notifyListeners();
  }

  Map<String, List<RoomInfo>> _visibleRooms(
    Map<String, List<RoomInfo>> rooms,
  ) => rooms.map(
    (epk, entries) => MapEntry(
      epk,
      entries.where((r) => !_prefs.isSessionHidden(epk, r.roomId)).toList(),
    ),
  );

  List<HomeItem> get allItems => state is HomeList
      ? (state as HomeList).items(normalizeEpk: normalizeEpkForLookup)
      : const [];

  Map<String, PeerRecord> get devices {
    final current = state;
    if (current is! HomeList) return const {};
    final peers = [...current.peers]
      ..sort(
        (a, b) => (a.nickname ?? a.sessionName).toLowerCase().compareTo(
          (b.nickname ?? b.sessionName).toLowerCase(),
        ),
      );
    return {for (final peer in peers) toStandardB64(peer.remoteEpk): peer};
  }

  String? get selectedDevice {
    final choices = devices;
    final remembered = _prefs.selectedDeviceEpk;
    if (choices.containsKey(remembered)) return remembered;
    final active = _prefs.selectedPeerEpk;
    if (active != null && choices.containsKey(toStandardB64(active))) {
      return toStandardB64(active);
    }
    return choices.keys.firstOrNull;
  }

  List<HomeItem> get deviceItems => allItems
      .where((item) => toStandardB64(item.peer.remoteEpk) == selectedDevice)
      .toList();

  String workspaceKeyFor(HomeItem item) =>
      _prefs.workspaceForSession(item.peer.remoteEpk, item.room.roomId) ??
      inboxWorkspaceKey(toStandardB64(item.peer.remoteEpk));

  String? workspaceLabel(String? key) {
    if (key == null) return null;
    final custom = _prefs.workspaceName(key);
    if (custom != null) return custom;
    return isInboxWorkspace(key) ? appL10n.inbox : workspaceId(key);
  }

  Future<String> createWorkspace({
    required String name,
    required String deviceEpk,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError('A workspace needs a name.');
    }
    final device = toStandardB64(deviceEpk);
    final key = workspaceKey(device, newLogicalWorkspaceId());
    await _prefs.setWorkspaceName(key, name);
    await _prefs.setSelectedWorkspace(key);
    return key;
  }

  bool isCustomWorkspace(String key) => _prefs.isCustomWorkspace(key);

  bool canDeleteWorkspace(String key) => _prefs.canDeleteWorkspace(key);

  /// Deleting returns the workspace's sessions to Inbox without deleting their
  /// computer history.
  Future<void> deleteWorkspace(String key) => _prefs.deleteWorkspace(key);

  /// Rename a phone-side workspace. The key is stable, so sessions assigned to
  /// it keep their grouping.
  Future<void> renameWorkspace(String key, String name) {
    if (name.trim().isEmpty) return Future.value();
    return _prefs.setWorkspaceName(key, name);
  }

  Future<void> assignSessionToWorkspace(HomeItem item, String workspaceKey) =>
      _prefs.setSessionWorkspace(
        item.peer.remoteEpk,
        item.room.roomId,
        workspaceKey,
      );

  Future<void> assignSessionRoomToWorkspace(
    String deviceEpk,
    String roomId,
    String workspaceKey,
  ) => _prefs.setSessionWorkspace(deviceEpk, roomId, workspaceKey);

  /// Name shown in lists and the chat header. A phone-local rename wins over
  /// the room name announced by the computer.
  String displayNameOf(HomeItem item) =>
      _prefs.sessionName(item.peer.remoteEpk, item.room.roomId) ??
      item.displayName;

  Future<void> renameSession(HomeItem item, String? name) =>
      _prefs.setSessionName(item.peer.remoteEpk, item.room.roomId, name);

  /// Rename the paired computer from the sidebar device card.
  Future<void> renameDevice(String epk, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final peers = switch (state) {
      HomeList(:final peers) => peers,
      _ => const <PeerRecord>[],
    };
    PeerRecord? target;
    for (final peer in peers) {
      if (toStandardB64(peer.remoteEpk) == toStandardB64(epk)) {
        target = peer;
        break;
      }
    }
    if (target == null) return;
    await _storage.savePeer(target.copyWith(nickname: trimmed));
  }

  /// Remove a paired computer and its phone-local session cache.
  ///
  /// Device management lives in the sidebar.
  Future<void> deleteDevice(String epk) async {
    final key = toStandardB64(epk);
    final target = devices[key];
    if (target == null) return;

    final activeEpk = _conn.activePeer?.remoteEpk;
    final wasActive =
        activeEpk != null && toStandardB64(activeEpk) == key ||
        _prefs.selectedPeerEpk != null &&
            toStandardB64(_prefs.selectedPeerEpk!) == key;

    if (_prefs.selectedDeviceEpk == key) {
      await _prefs.setSelectedDevice(null);
    }
    if (_prefs.selectedPeerEpk != null &&
        toStandardB64(_prefs.selectedPeerEpk!) == key) {
      await _prefs.setSelectedRoom();
    }

    if (_sync != null) {
      for (final item in allItems.where(
        (item) => toStandardB64(item.peer.remoteEpk) == key,
      )) {
        try {
          await _sync.removeCachedSession(
            item.peer.remoteEpk,
            item.room.roomId,
          );
        } catch (_) {
          // Removing the pairing must still succeed if a local cache entry is
          // already gone or temporarily unavailable.
        }
      }
    }
    await _storage.deleteRooms(target.remoteEpk);
    await _storage.deletePeer(target.remoteEpk);

    final remaining = await _storage.listPeers();
    _conn.subscribeToPeers(remaining.map((peer) => peer.remoteEpk).toList());
    if (wasActive) {
      await _conn.disconnect();
      if (remaining.isNotEmpty) {
        final fallback = remaining.first;
        await _prefs.setSelectedPeerEpk(fallback.remoteEpk);
        // ignore: unawaited_futures
        _conn.boot(preferredEpk: fallback.remoteEpk);
      }
    }
    if (remaining.isEmpty) {
      await _prefs.setOnboardingCompleted(false);
    }
  }

  /// Workspace id → the secondary line shown in the workspace picker.
  Map<String, String> workspacesForDevice(String deviceEpk) {
    final device = toStandardB64(deviceEpk);
    final result = <String, String>{inboxWorkspaceKey(device): ''};
    for (final key in _prefs.customWorkspaceKeysForDevice(device)) {
      result[key] = '';
    }
    for (final item in allItems.where(
      (item) => toStandardB64(item.peer.remoteEpk) == device,
    )) {
      final key = workspaceKeyFor(item);
      result.putIfAbsent(key, () => item.room.cwd ?? '');
    }
    for (final key in result.keys.toList()) {
      final items = _itemsInWorkspace(key);
      final folders = items
          .map((item) => item.room.cwd)
          .whereType<String>()
          .toSet();
      result[key] = items.isEmpty
          ? appL10n.noSessionsYet
          : '${appL10n.sessionCount(items.length)}'
                '${folders.length > 1 ? appL10n.folderCountSuffix(folders.length) : ''}';
    }
    return result;
  }

  Map<String, String> get workspaces {
    final device = selectedDevice;
    return device == null
        ? const <String, String>{}
        : workspacesForDevice(device);
  }

  /// Workspace choices for every paired computer. New Session shows only the
  /// entries matching its currently selected computer.
  List<WorkspaceGroup> get workspaceGroups {
    final result = <WorkspaceGroup>[];
    for (final device in devices.keys) {
      for (final entry in workspacesForDevice(device).entries) {
        result.add(
          WorkspaceGroup(
            workspaceKey: entry.key,
            deviceId: device,
            label: workspaceLabel(entry.key) ?? entry.key,
            subtitle: entry.value,
          ),
        );
      }
    }
    return result;
  }

  String? workspaceSubtitle(String key) => workspaces[key];

  String? get selectedWorkspace {
    final choices = workspaces;
    final device = selectedDevice;
    final remembered = device == null
        ? null
        : _prefs.workspaceForDevice(device);
    if (choices.containsKey(remembered)) return remembered;
    for (final item in deviceItems) {
      if (toStandardB64(item.peer.remoteEpk) ==
              (_prefs.selectedPeerEpk == null
                  ? null
                  : toStandardB64(_prefs.selectedPeerEpk!)) &&
          item.room.roomId == _prefs.selectedRoomId) {
        return workspaceKeyFor(item);
      }
    }
    return choices.keys.firstOrNull;
  }

  List<HomeItem> _itemsInWorkspace(String workspaceKey) {
    final separator = workspaceKey.indexOf(':');
    if (separator < 1) return const [];
    final epk = workspaceKey.substring(0, separator);
    return allItems
        .where(
          (item) =>
              toStandardB64(item.peer.remoteEpk) == epk &&
              workspaceKeyFor(item) == workspaceKey,
        )
        .toList();
  }

  List<HomeItem> get workspaceItems {
    final selected = selectedWorkspace;
    if (selected == null) return const [];
    return _itemsInWorkspace(selected);
  }

  Future<void> selectDevice(String epk) async {
    final key = toStandardB64(epk);
    if (devices.containsKey(key)) await _prefs.setSelectedDevice(key);
  }

  Future<void> selectWorkspace(String key) async {
    if (workspaces.containsKey(key)) await _prefs.setSelectedWorkspace(key);
  }

  Future<void> deleteSession(HomeItem item) async {
    final epk = item.peer.remoteEpk, room = item.room.roomId;
    await _prefs.hideSession(epk, room);
    try {
      await _sync?.removeCachedSession(epk, room);
    } catch (_) {
      await _prefs.restoreSession(epk, room);
      rethrow;
    }
    if (_prefs.selectedPeerEpk == epk &&
        _prefs.isSessionHidden(epk, _prefs.selectedRoomId ?? 'main')) {
      await _prefs.setSelectedRoom();
    }
  }

  /// Reconcile phone-local session caches against the active computer's
  /// persisted Pi session catalog.
  ///
  /// Fail-closed: an offline channel, a timed-out request, or an incomplete
  /// response leaves every cache intact. A complete response prunes the
  /// cached sessions whose room the computer no longer has.
  Future<void> refreshComputerSessionInventory({bool force = false}) async {
    final actions = _actions;
    final peer = _conn.activePeer;
    if (actions == null || !_connected || peer == null) return;
    if (_inventoryRefreshInFlight) return;
    final last = _lastInventoryRefresh;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 10)) {
      return;
    }

    final expectedEpk = toStandardB64(peer.remoteEpk);
    _inventoryRefreshInFlight = true;
    try {
      final inventory = await actions.listSessionsInventory();
      if (_disposed ||
          _conn.activePeer == null ||
          toStandardB64(_conn.activePeer!.remoteEpk) != expectedEpk) {
        return;
      }
      await reconcileSessionInventoryForPeer(
        expectedEpk,
        roomIds: inventory.roomIds,
        scannedAt: inventory.scannedAt,
      );
      _lastInventoryRefresh = DateTime.now();
    } catch (_) {
      // Keep the cache and try again on the next connect/foreground.
    } finally {
      _inventoryRefreshInFlight = false;
    }
  }

  /// Applies one complete inventory snapshot for [peerEpk].
  ///
  /// Returns the number of phone-local sessions removed. The scan timestamp is
  /// a race guard: a session announced after the scan began must never be
  /// mistaken for a deleted one.
  Future<int> reconcileSessionInventoryForPeer(
    String peerEpk, {
    required Set<String> roomIds,
    required int scannedAt,
  }) async {
    if (scannedAt <= 0) return 0;
    final normalized = toStandardB64(peerEpk);
    final snapshot = allItems
        .where((item) => toStandardB64(item.peer.remoteEpk) == normalized)
        .toList(growable: false);
    var removed = 0;
    for (final item in snapshot) {
      if (item.room.startedAt > scannedAt) continue;
      if (roomIds.contains(item.room.roomId)) continue;
      try {
        await deleteSession(item);
        removed++;
      } catch (_) {
        // Keep local history when cache cleanup fails; a later refresh retries.
      }
    }
    return removed;
  }

  void _onStorageChanged() {
    if (_disposed) return;
    _load();
  }

  /// `true` when `(epk, roomId)`'s agent is currently mid-turn. Drives
  /// the blue "working" dot on the Home tile.
  ///
  /// The host pushes `working` for every room, so this reflects every
  /// session, connected or not. The DB session index is deliberately not
  /// consulted: it only stays fresh for the connected room.
  bool isRoomWorking(String epk, String roomId) =>
      _conn.isRoomWorking(epk, roomId);

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const HomeNoPeer());
      return;
    }
    // Subscribe presence and rooms for every computer; idempotent.
    _conn.subscribeToPeers(peers.map((p) => p.remoteEpk).toList());
    emit(
      HomeList(
        peers: peers,
        statusByEpk: _conn.presenceSnapshot,
        roomsByPeer: _visibleRooms(_conn.roomsSnapshot),
      ),
    );
    if (_connected) {
      // ignore: unawaited_futures
      refreshComputerSessionInventory();
    }
  }

  void _onPresence(Map<String, PresenceState> snapshot) {
    final s = state;
    if (s is! HomeList) return;
    emit(s.copyWith(statusByEpk: snapshot));
  }

  void _onRooms(Map<String, List<RoomInfo>> snapshot) {
    final s = state;
    if (s is! HomeList) return;
    emit(s.copyWith(roomsByPeer: _visibleRooms(snapshot)));
  }

  void _onStatus(ConnectionStatus status) {
    final next = status is StatusOnline;
    final changed = next != _connected;
    _connected = next;
    if (next) {
      // ignore: unawaited_futures
      refreshComputerSessionInventory();
    }
    if (!changed) return;
    // Trigger a re-render of any HomeList so tiles re-evaluate dot
    // colour (room-live vs reconnecting).
    final s = state;
    if (s is HomeList) {
      // emit a duplicate-looking HomeList so context.watch() triggers
      // even though peers / roomsByPeer / presence didn't change.
      // Preserve `filter` — otherwise a status flip would silently reset
      // the user's tab back to the Online default (and, because the new
      // object would then differ, actually fire that reset).
      emit(
        HomeList(
          peers: s.peers,
          statusByEpk: s.statusByEpk,
          roomsByPeer: s.roomsByPeer,
          filter: s.filter,
        ),
      );
    }
  }

  /// Switch the presence tab. No reload: it only swaps the
  /// `filter` in state so [visibleItems] re-derives. No-op when the state
  /// isn't a list or the filter is unchanged.
  void setFilter(HomeFilter filter) {
    final s = state;
    if (s is! HomeList) return;
    if (s.filter == filter) return;
    emit(s.copyWith(filter: filter));
  }

  /// `true` when `(epk, roomId)` is live on its computer, through whichever
  /// connection carries it. The single source for the Online/Offline split.
  bool _online(HomeItem it) =>
      _conn.isRoomLive(it.peer.remoteEpk, it.room.roomId);

  /// The items the current [HomeList.filter] keeps. A pure
  /// view over `state.items()`; returns `const []` outside a list state.
  List<HomeItem> get visibleItems {
    final s = state;
    if (s is! HomeList) return const [];
    final all = s.items(normalizeEpk: normalizeEpkForLookup);
    return switch (s.filter) {
      HomeFilter.all => all,
      HomeFilter.online => all.where(_online).toList(),
      HomeFilter.offline => all.where((i) => !_online(i)).toList(),
    };
  }

  /// Per-tab counts for the filter badges. Independent of
  /// the active tab (each badge always shows its own slice's size).
  ({int all, int online, int offline}) get counts {
    final s = state;
    if (s is! HomeList) return (all: 0, online: 0, offline: 0);
    final all = s.items(normalizeEpk: normalizeEpkForLookup);
    final online = all.where(_online).length;
    return (all: all.length, online: online, offline: all.length - online);
  }

  /// Remember which (peer, room) the user picked, persist it on the
  /// PeerRecord so the next cold start reconnects to it, and switch the
  /// ConnectionManager's active room.
  Future<void> openSession(String epk, {String? roomId}) async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    final match = peers.where((p) => p.remoteEpk == epk).cast<PeerRecord?>();
    if (match.isEmpty) return;
    final peer = match.first!;
    final effectiveRoom = (roomId == null || roomId.isEmpty) ? 'main' : roomId;
    final explicitWorkspace = _prefs.workspaceForSession(epk, effectiveRoom);
    await _prefs.setSelectedWorkspace(
      explicitWorkspace ?? inboxWorkspaceKey(epk),
    );
    await _prefs.restoreSession(epk, effectiveRoom);
    await _prefs.setSelectedRoom(epk: epk, roomId: effectiveRoom);
    if (peer.roomId != effectiveRoom) {
      // ignore: unawaited_futures
      _storage.savePeer(peer.copyWith(roomId: effectiveRoom));
    }
    // Tell the manager which Pi-side room to address. Safe to call
    // even if the manager is mid-connect (room is applied on the next
    // send and any active StatusOnline channel).
    _conn.switchRoom(effectiveRoom);
  }

  /// Helper for widgets: pass a peer's url-safe epk → returns standard
  /// for indexing into [HomeList.roomsByPeer] / [HomeList.statusByEpk].
  static String normalizeEpkForLookup(String epk) => toStandardB64(epk);

  /// `true` if `(epk, roomId)` is currently live on its computer. Drives
  /// the presence dot on each tile.
  bool isRoomLive(String epk, String roomId) => _conn.isRoomLive(epk, roomId);

  /// Long-press menu — rename a single room locally (Pi never sees it).
  Future<void> renameRoom(String epk, String roomId, String? name) =>
      _conn.setRoomLocalName(epk, roomId, name);

  /// Long-press menu — delete a cached room locally. Caller should
  /// gate on `!isRoomLive` (only offline rooms can be removed).
  Future<void> deleteRoom(String epk, String roomId) =>
      _conn.deleteCachedRoom(epk, roomId);

  @override
  void dispose() {
    _disposed = true;
    _presenceSub?.cancel();
    _roomsSub?.cancel();
    _statusSub?.cancel();
    _storage.removeListener(_onStorageChanged);
    _prefs.removeListener(_onPreferencesChanged);
    super.dispose();
  }
}
