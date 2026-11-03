import 'dart:async';

import 'package:app/acp/acp.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/states/home_state.dart';

/// Home: every paired computer and its sessions, live from [Hosts], plus the
/// phone-side organisation (workspaces, local names) kept in [Preferences].
class HomeViewModel extends ViewModel<HomeState> {
  final Hosts _hosts;
  final PairingStorage _storage;
  final Preferences _prefs;
  bool _disposed = false;

  HomeViewModel(this._hosts, this._storage, this._prefs)
    : super(const HomeLoading()) {
    _hosts.addListener(_load);
    _prefs.addListener(_onPreferencesChanged);
    _load();
  }

  void _onPreferencesChanged() {
    if (!_disposed) notifyListeners();
  }

  List<HomeItem> get allItems => state is HomeList
      ? (state as HomeList).items(normalizeEpk: normalizeEpkForLookup)
      : const [];

  Map<String, PeerRecord> get devices {
    final current = state;
    if (current is! HomeList) return const {};
    final peers = [...current.peers]
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return {for (final peer in peers) toStandardB64(peer.remoteEpk): peer};
  }

  String? get selectedDevice {
    final choices = devices;
    final remembered = _prefs.selectedDeviceEpk;
    if (choices.containsKey(remembered)) return remembered;
    return choices.keys.firstOrNull;
  }

  List<HomeItem> get deviceItems => allItems
      .where((item) => toStandardB64(item.peer.remoteEpk) == selectedDevice)
      .toList();

  String workspaceKeyFor(HomeItem item) =>
      _prefs.workspaceForSession(item.peer.remoteEpk, item.sessionId) ??
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
        item.sessionId,
        workspaceKey,
      );

  Future<void> assignSessionRoomToWorkspace(
    String deviceEpk,
    String roomId,
    String workspaceKey,
  ) => _prefs.setSessionWorkspace(deviceEpk, roomId, workspaceKey);

  /// Name shown in lists and the chat header. A phone-local rename wins over
  /// the title the computer gives the session.
  String displayNameOf(HomeItem item) =>
      _prefs.sessionName(item.peer.remoteEpk, item.sessionId) ??
      item.displayName;

  Future<void> renameSession(HomeItem item, String? name) =>
      _prefs.setSessionName(item.peer.remoteEpk, item.sessionId, name);

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

  /// Forget a paired computer on this phone.
  Future<void> deleteDevice(String epk) async {
    final key = toStandardB64(epk);
    final target = devices[key];
    if (target == null) return;
    if (_prefs.selectedDeviceEpk == key) await _prefs.setSelectedDevice(null);
    await _storage.deleteSessions(target.remoteEpk);
    await _storage.deletePeer(target.remoteEpk);
    if ((await _storage.listPeers()).isEmpty) {
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
      result.putIfAbsent(key, () => item.session.cwd);
    }
    for (final key in result.keys.toList()) {
      final items = _itemsInWorkspace(key);
      final folders = items.map((item) => item.session.cwd).toSet();
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

  /// Deletes the session and its history on the computer.
  Future<void> deleteSession(HomeItem item) async {
    final host = _hosts.byKey(item.peer.remoteEpk);
    if (host == null) return;
    await host.call('session/delete', {'sessionId': item.sessionId});
  }

  /// `true` when the session's agent is mid-turn: the blue dot.
  bool isRoomWorking(String epk, String sessionId) =>
      _hosts.find(epk, sessionId)?.session.working ?? false;

  void _load() {
    if (_disposed) return;
    if (!_hosts.loaded) return;
    final hosts = _hosts.all;
    if (hosts.isEmpty) {
      emit(const HomeNoPeer());
      return;
    }
    final current = state;
    emit(
      HomeList(
        peers: [for (final host in hosts) host.host],
        onlineByEpk: {
          for (final host in hosts) toStandardB64(host.key): host.isOnline,
        },
        sessionsByPeer: {
          for (final host in hosts) toStandardB64(host.key): host.sessions,
        },
        filter: current is HomeList ? current.filter : HomeFilter.online,
      ),
    );
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

  /// `true` when the session's computer is connected: the Online/Offline split.
  bool _online(HomeItem it) =>
      _hosts.byKey(it.peer.remoteEpk)?.isOnline ?? false;

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

  /// Remember the workspace of the session the user opened.
  Future<void> openSession(String epk, String sessionId) async {
    final explicitWorkspace = _prefs.workspaceForSession(epk, sessionId);
    await _prefs.setSelectedWorkspace(
      explicitWorkspace ?? inboxWorkspaceKey(toStandardB64(epk)),
    );
  }

  /// Helper for widgets: any base64 key → the standard form used as map key.
  static String normalizeEpkForLookup(String epk) => toStandardB64(epk);

  /// `true` when the session's computer is connected.
  bool isRoomLive(String epk, String sessionId) =>
      _hosts.byKey(epk)?.isOnline ?? false;

  /// The computer, for agents and connection state.
  bool isDeviceOnline(String epk) => _hosts.byKey(epk)?.isOnline ?? false;

  List<AgentInfo> agentsOf(String epk) => _hosts.byKey(epk)?.agents ?? const [];

  @override
  void dispose() {
    _disposed = true;
    _hosts.removeListener(_load);
    _prefs.removeListener(_onPreferencesChanged);
    super.dispose();
  }
}
