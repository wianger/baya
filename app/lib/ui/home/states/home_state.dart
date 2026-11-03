import 'package:app/acp/acp.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;

sealed class HomeState {
  const HomeState();
}

/// Which presence slice of the Home list is shown. A pure view filter.
enum HomeFilter { all, online, offline }

class HomeLoading extends HomeState {
  const HomeLoading();
}

class HomeNoPeer extends HomeState {
  const HomeNoPeer();
}

/// Single row on Home: one session on a paired computer.
class HomeItem {
  final PeerRecord peer;
  final SessionSummary session;

  const HomeItem({required this.peer, required this.session});

  String get sessionId => session.sessionId;
  String get displayName => session.title;

  @override
  bool operator ==(Object other) =>
      other is HomeItem &&
      other.peer.remoteEpk == peer.remoteEpk &&
      other.session == session;

  @override
  int get hashCode => Object.hash(peer.remoteEpk, session);
}

/// Paired computers, whether each is connected, and their sessions.
class HomeList extends HomeState {
  final List<PeerRecord> peers;

  /// Standard-base64 key → connected right now.
  final Map<String, bool> onlineByEpk;

  /// Standard-base64 key → sessions on that computer.
  final Map<String, List<SessionSummary>> sessionsByPeer;
  final HomeFilter filter;

  const HomeList({
    required this.peers,
    this.onlineByEpk = const {},
    this.sessionsByPeer = const {},
    this.filter = HomeFilter.online,
  });

  HomeList copyWith({HomeFilter? filter}) => HomeList(
    peers: peers,
    onlineByEpk: onlineByEpk,
    sessionsByPeer: sessionsByPeer,
    filter: filter ?? this.filter,
  );

  /// One row per (computer, session): computers by label, sessions newest
  /// first.
  List<HomeItem> items({required String Function(String) normalizeEpk}) {
    final sortedPeers = [...peers]
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return [
      for (final peer in sortedPeers)
        for (final session
            in sessionsByPeer[normalizeEpk(peer.remoteEpk)] ??
                const <SessionSummary>[])
          HomeItem(peer: peer, session: session),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is HomeList &&
      other.filter == filter &&
      listEquals(other.peers, peers) &&
      mapEquals(other.onlineByEpk, onlineByEpk) &&
      _sameSessions(other.sessionsByPeer, sessionsByPeer);

  static bool _sameSessions(
    Map<String, List<SessionSummary>> a,
    Map<String, List<SessionSummary>> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!listEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    filter,
    Object.hashAll(peers),
    Object.hashAllUnordered(
      onlineByEpk.entries.map((e) => '${e.key}:${e.value}'),
    ),
    Object.hashAllUnordered(
      sessionsByPeer.entries.map(
        (e) => Object.hash(e.key, Object.hashAll(e.value)),
      ),
    ),
  );
}
