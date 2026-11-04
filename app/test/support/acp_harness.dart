// An in-memory Baya computer speaking ACP, for tests: it answers the same
// requests the real host does and lets a test push updates and permission
// questions.

import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:app/acp/acp.dart';
import 'package:app/acp/json_rpc.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/transport/host_socket.dart';
import 'package:app/data/transport/noise.dart' show DataFrame;
import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord testPeer({int seed = 5, String name = 'PC', String? nickname}) =>
    PeerRecord(
      remoteEpk: base64Encode(List.filled(32, seed)),
      name: name,
      endpoint: 'https://pc.example/baya-pair/wsl/direct',
      pairedAt: '2026-10-30T00:00:00Z',
      nickname: nickname,
    );

SessionSummary testSession({
  String id = 's1',
  String cwd = '/code/app',
  String? title,
  String agent = 'claude',
  String agentName = 'Claude Code',
  bool working = false,
  DateTime? updatedAt,
}) => SessionSummary(
  sessionId: id,
  cwd: cwd,
  title: title ?? folderName(cwd),
  agent: agent,
  agentName: agentName,
  working: working,
  running: true,
  updatedAt: updatedAt ?? DateTime.utc(2026, 11, 1),
);

/// Pairings and cached session lists in memory.
class MemoryStorage extends PairingStorage {
  MemoryStorage([List<PeerRecord>? peers]) : peers = [...?peers];

  final List<PeerRecord> peers;
  final sessions = <String, List<SessionSummary>>{};

  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);

  @override
  Future<PeerRecord?> loadPeer(String remoteEpk) async =>
      peers.where((p) => p.remoteEpk == remoteEpk).firstOrNull;

  @override
  Future<void> savePeer(PeerRecord record) async {
    peers
      ..removeWhere((p) => p.remoteEpk == record.remoteEpk)
      ..add(record);
    notifyListeners();
  }

  @override
  Future<void> deletePeer(String remoteEpk) async {
    peers.removeWhere((p) => p.remoteEpk == remoteEpk);
    notifyListeners();
  }

  @override
  Future<void> wipeAll() async {
    peers.clear();
    sessions.clear();
    notifyListeners();
  }

  @override
  Future<void> saveSessions(String remoteEpk, List<SessionSummary> list) async {
    sessions[remoteEpk] = list;
  }

  @override
  Future<List<SessionSummary>> loadSessions(String remoteEpk) async =>
      sessions[remoteEpk] ?? const [];

  @override
  Future<void> deleteSessions(String remoteEpk) async {
    sessions.remove(remoteEpk);
  }
}

/// A scripted computer. Each connection gets a fresh [FakeHostSocket].
class FakeHost {
  FakeHost({
    List<SessionSummary>? sessions,
    this.agents = const [AgentInfo('claude', 'Claude Code')],
    this.hostname = 'studio',
  }) : sessions = [...?sessions];

  final List<SessionSummary> sessions;
  final List<AgentInfo> agents;
  final String hostname;

  /// History `session/load` replays, per session.
  final history = <String, List<Json>>{};

  /// What `session/load` returns (config options, modes).
  Json setup = {
    '_meta': {
      'baya': {
        'agentName': 'Claude Code',
        'promptCapabilities': {'image': true},
      },
    },
  };

  /// Updates a prompt streams before it ends, and its stop reason.
  List<Json> reply = [
    {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': 'Done.'},
    },
  ];
  String stopReason = 'end_turn';

  /// Answers to override, by method.
  final handlers = <String, FutureOr<Object?> Function(Json params)>{};

  /// Every request the phone sent, in order.
  final calls = <({String method, Json params})>[];

  /// Set to make the next connection fail.
  Object? refuse;

  /// When set, `initialize` fails as for an unpaired phone.
  bool unpaired = false;

  FakeHostSocket? socket;
  int connections = 0;

  Future<HostSocket> connect({
    required String endpoint,
    required String hostKey,
    required SimpleKeyPair identity,
  }) async {
    if (refuse != null) throw refuse!;
    connections++;
    return socket = FakeHostSocket(this);
  }

  /// Sends a notification to the connected phone.
  void push(String method, Json params) => socket?.peer.notify(method, params);

  void update(String sessionId, Json update) =>
      push('session/update', {'sessionId': sessionId, 'update': update});

  /// Asks the phone to fill in a form (or open a link).
  Future<Object?> askElicitation(Json params) =>
      socket!.peer.request('elicitation/create', params);

  /// Asks the phone a permission question; completes with its answer.
  Future<Object?> askPermission(Json params) =>
      socket!.peer.request('session/request_permission', params);

  Future<Object?> _handle(String method, Json params) async {
    calls.add((method: method, params: params));
    final custom = handlers[method];
    if (custom != null) return custom(params);
    switch (method) {
      case 'initialize':
        if (unpaired) {
          throw const RpcError(RpcError.notPaired, 'not paired', {
            'reason': 'unpaired',
          });
        }
        return {
          'protocolVersion': 1,
          'agentInfo': {'name': 'baya', 'version': '3.0.0'},
          '_meta': {
            'baya': {
              'hostname': hostname,
              'agents': [
                for (final a in agents)
                  {'id': a.id, 'name': a.name, 'available': a.available},
              ],
            },
          },
        };
      case 'session/list':
        return {
          'sessions': [for (final s in sessions) s.toJson()],
        };
      case 'session/load':
        final id = params['sessionId'] as String;
        for (final update in history[id] ?? const <Json>[]) {
          this.update(id, update);
        }
        return setup;
      case 'session/new':
        final id = 'new-${sessions.length + 1}';
        final cwd = params['cwd'] as String;
        final summary = testSession(id: id, cwd: cwd);
        sessions.add(summary);
        push('_baya/session_changed', {'session': summary.toJson()});
        return {'sessionId': id, ...setup};
      case 'session/prompt':
        final id = params['sessionId'] as String;
        final meta = bayaMeta(params);
        for (final block in params['prompt'] as List) {
          update(id, {
            'sessionUpdate': 'user_message_chunk',
            'content': block,
            'messageId': meta['messageId'],
          });
        }
        for (final update in reply) {
          this.update(id, update);
        }
        return {'stopReason': stopReason};
      case 'session/delete':
        final id = params['sessionId'];
        sessions.removeWhere((s) => s.sessionId == id);
        push('_baya/session_removed', {'sessionId': id});
        return const <String, dynamic>{};
      case 'session/close':
      case 'session/set_mode':
        return const <String, dynamic>{};
      case 'session/set_config_option':
        return {'configOptions': setup['configOptions'] ?? const <Object>[]};
      case '_baya/browse':
        return {
          'path': params['path'] ?? '/home/me',
          'parent': null,
          'home': '/home/me',
          'roots': ['/'],
          'directories': [
            {'name': 'code', 'path': '/home/me/code'},
          ],
          'truncated': false,
        };
      default:
        throw RpcError(RpcError.methodNotFound, 'Method not found: $method');
    }
  }
}

class FakeHostSocket implements HostSocket {
  FakeHostSocket(this.host) {
    peer = JsonRpcPeer(
      write: (message) => scheduleMicrotask(() {
        if (!_messages.isClosed) {
          _messages.add(jsonDecode(jsonEncode(message)) as Json);
        }
      }),
      onRequest: (method, params, _) => host._handle(method, params),
      onNotification: (method, params) =>
          notifications.add((method: method, params: params)),
    );
  }

  final FakeHost host;
  late final JsonRpcPeer peer;
  final _messages = StreamController<Json>.broadcast();
  final _closed = Completer<SocketClosed>();
  final notifications = <({String method, Json params})>[];

  @override
  Stream<Json> get messages => _messages.stream;

  @override
  void send(Json message) =>
      scheduleMicrotask(() => peer.receive(jsonDecode(jsonEncode(message))));

  @override
  Future<SocketClosed> get closed => _closed.future;

  /// File bytes the computer streams; tests add to it.
  final dataFrames = StreamController<DataFrame>.broadcast();

  /// File bytes the phone sent.
  final sentData = <DataFrame>[];

  @override
  Stream<DataFrame> get data => dataFrames.stream;

  @override
  Future<void> sendData(int stream, int offset, List<int> bytes) async =>
      sentData.add(DataFrame(stream, offset, Uint8List.fromList(bytes)));

  /// The computer closes the socket.
  void drop([int? code, String? reason]) {
    if (_closed.isCompleted) return;
    peer.close(const RpcClosed('closed'));
    _closed.complete(SocketClosed(code, reason));
    unawaited(_messages.close());
  }

  @override
  Future<void> close() async => drop();
}

/// [Hosts] over [storage], every computer answered by [host].
Hosts testHosts(MemoryStorage storage, FakeHost host) => Hosts(
  storage: storage,
  connect: host.connect,
  identity: () => Ed25519().newKeyPair(),
);

/// Lets queued microtasks and timers of zero length run.
Future<void> settle([int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Pumps until every computer in [hosts] is connected (widget tests).
Future<void> pumpOnline(WidgetTester tester, Hosts hosts) async {
  for (var i = 0; i < 50 && !hosts.all.every((h) => h.isOnline); i++) {
    await tester.pump();
  }
}

/// [Hosts] where each computer (by key) is its own [FakeHost]; computers
/// not in [hosts] are unreachable.
Hosts testHostsFor(MemoryStorage storage, Map<String, FakeHost> hosts) => Hosts(
  storage: storage,
  connect: ({required endpoint, required hostKey, required identity}) {
    final host = hosts[hostKey];
    if (host == null) throw Exception('unreachable');
    return host.connect(
      endpoint: endpoint,
      hostKey: hostKey,
      identity: identity,
    );
  },
  identity: () => Ed25519().newKeyPair(),
);
