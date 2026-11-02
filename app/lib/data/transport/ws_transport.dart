// WebSocket-based PeerTransport.
//
// Flow per connection:
//   1. Connect to relay WS
//   2. Ed25519 challenge-response (hello → challenge → auth)
//   3. After auth, two parallel streams of inbound frames:
//        - envelope frames `{peer, ct}` → decoded to the peer queue
//        - control frames (top-level `type`, no `peer`) → control stream
//      Outbound `subscribe_presence` / `presence_check` go raw too.
//
// `peer` is standard base64 of the destination's Ed25519 pubkey (matches
// the relay registry, populated from the peer's hello). `ct` is base64 of
// the end-to-end encrypted inner frame (see e2e.dart).

import 'dart:async';
import 'dart:convert';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/e2e.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../pairing/pair_request_flow.dart';

class WsTransportError implements Exception {
  final String message;
  const WsTransportError(this.message);

  @override
  String toString() => 'WsTransportError: $message';
}

class WsTransport implements PeerTransport, IControlLink {
  final WebSocketChannel _ws;
  final _queue = _MsgQueue();
  final _controlController = StreamController<ControlInbound>.broadcast();

  WsTransport._(this._ws);

  // Connect, authenticate with relay, and return a ready transport.
  static Future<WsTransport> connect({
    required String endpoint,
    required String peerPubkey, // base64 standard or url — destination peer
    required SimpleKeyPair ed25519Key, // this device's Ed25519 long-term key
  }) async {
    // Set a WS-level pingInterval (RFC 6455
    // control frames). This keeps the TCP connection alive through
    // NAT / corporate proxies that aggressively close idle sockets,
    // and surfaces a dead WS as `onDone` / `onError` instead of
    // letting it silently linger until the next user action. The
    // protocol-level Ping/Pong handled by ConnectionManager covers
    // app↔Pi liveness; this one covers app↔relay TCP liveness.
    // Accept http(s) URLs in the user-facing form but always speak
    // ws(s) on the wire — IOWebSocketChannel rejects http schemes.
    final WebSocketChannel ws = IOWebSocketChannel.connect(
      _webSocketUri(endpoint),
      pingInterval: const Duration(seconds: 20),
    );
    final transport = WsTransport._(ws);

    final challengeCompleter = Completer<Map<String, dynamic>>();
    bool authDone = false;

    final sub = ws.stream.listen(
      (raw) {
        // Volume probe: log every frame the relay pushes onto this
        // socket so we can spot firehose patterns (e.g. presence
        // churn, repeated room snapshots) by counting prefix
        // occurrences — body kept compact so the log stays grep-able
        // even when the relay is chatty.
        final rawStr = raw is String ? raw : raw.toString();
        if (!authDone) {
          debugPrint('[ws-in] bytes=${rawStr.length} stage=preauth');
          try {
            challengeCompleter.complete(
              jsonDecode(raw as String) as Map<String, dynamic>,
            );
          } catch (e) {
            if (!challengeCompleter.isCompleted) {
              challengeCompleter.completeError(e);
            }
          }
          return;
        }
        try {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          // Envelope: {peer, room, ct}. The transport is shared across
          // chats, so frames from a room other than the addressed one are
          // dropped instead of bleeding into the chat on screen.
          if (frame.containsKey('peer') && frame.containsKey('ct')) {
            final bytes = _b64Decode(frame['ct'] as String);
            final senderRoom = frame['room'] as String?;
            if (senderRoom != transport._activeRoom) return;
            transport._receiveSealed(bytes, senderRoom!);
            return;
          }
          // Control: top-level `type` only → presence stream.
          final ctrl = ControlInbound.tryFromJson(frame);
          if (ctrl != null && !transport._controlController.isClosed) {
            debugPrint(
              '[ws-in] bytes=${rawStr.length} kind=control '
              'type=${frame['type']}',
            );
            transport._controlController.add(ctrl);
            return;
          }
          // Anything else: unknown shape — drop silently.
          debugPrint('[ws-in] bytes=${rawStr.length} kind=unknown DROPPED');
        } catch (e) {
          debugPrint(
            '[ws-in] bytes=${rawStr.length} kind=malformed DROPPED err=$e',
          );
        }
      },
      onError: (Object e) {
        if (!challengeCompleter.isCompleted) {
          challengeCompleter.completeError(e);
        }
        transport._queue.error(e);
      },
      onDone: () {
        if (!challengeCompleter.isCompleted) {
          challengeCompleter.completeError(
            const WsTransportError('WS closed during auth'),
          );
        }
        transport._queue.close();
        if (!transport._controlController.isClosed) {
          transport._controlController.close();
        }
      },
    );

    try {
      // 0. End-to-end key for this host, ready before any frame can arrive.
      final pub = await ed25519Key.extractPublicKey();
      transport._peerPubkey = _normalizeToStandard(peerPubkey);
      transport._key = await deriveSessionKey(
        selfSeed: await ed25519Key.extractPrivateKeyBytes(),
        selfPublic: pub.bytes,
        peerPublic: base64.decode(transport._peerPubkey),
      );

      // 1. Hello (standard base64 — matches relay registry format).
      // App is a client (no cwd) and always announces itself
      // on the canonical 'main' room. Pi-side hellos include their own
      // room_id (one per cwd) AND room_meta; that's not our concern here.
      ws.sink.add(
        jsonEncode({
          'type': 'hello',
          'pubkey': base64.encode(pub.bytes),
          'room_id': 'main',
        }),
      );

      // 2. Challenge
      final ch = await challengeCompleter.future;
      if (ch['type'] != 'challenge') {
        throw WsTransportError('Expected challenge, got ${ch['type']}');
      }
      final nonce = _b64Decode(ch['nonce'] as String);

      // 3. Auth
      final sig = await Ed25519().sign(nonce, keyPair: ed25519Key);
      ws.sink.add(
        jsonEncode({'type': 'auth', 'sig': base64.encode(sig.bytes)}),
      );
      authDone = true;

      transport._sub = sub;
      return transport;
    } catch (e) {
      await sub.cancel();
      await ws.sink.close();
      rethrow;
    }
  }

  String _peerPubkey = '';
  StreamSubscription<Object?>? _sub;
  late final SecretKey _key;
  final _replay = ReplayGuard();
  // Encryption is async; these chains keep frames in wire order.
  Future<void> _inbound = Future.value();
  Future<void> _outbound = Future.value();

  /// Active target room on the Pi side. Set via
  /// `setActiveRoom`, defaults to 'main' when unset. The outer envelope
  /// embeds this so the Pi can route the inner message to the right
  /// per-cwd session.
  String _activeRoom = 'main';

  /// Override the destination room (Pi side). The app remains on the
  /// 'main' room itself (that's what we sent in `hello.room_id`).
  void setActiveRoom(String room) {
    if (room == _activeRoom) {
      return;
    }
    _activeRoom = room;
  }

  @override
  Future<void> send(Uint8List data) {
    final room = _activeRoom;
    return _outbound = _outbound
        .then((_) async {
          final box = await seal(_key, E2EDirection.phoneToHost, room, data);
          _ws.sink.add(
            jsonEncode({
              'peer': _peerPubkey,
              'room': room,
              'ct': base64.encode(box),
            }),
          );
        })
        .catchError((Object e) {
          debugPrint('[ws-out] seal failed: $e');
        });
  }

  void _receiveSealed(Uint8List bytes, String room) {
    _inbound = _inbound
        .then((_) async {
          // Plaintext could have been written by the relay: never trust it.
          if (!isSealed(bytes)) return;
          final opened = await open(
            _key,
            E2EDirection.hostToPhone,
            room,
            bytes,
          );
          // Errors always pass so a "clock_skew" report reaches a phone whose
          // clock is the problem.
          if (!_replay.accept(opened) && !_isErrorFrame(opened.plaintext)) {
            debugPrint('[ws-in] stale or replayed frame DROPPED');
            return;
          }
          _queue.add(opened.plaintext);
        })
        .catchError((Object e) {
          debugPrint('[ws-in] envelope DROPPED err=$e');
        });
  }

  @override
  Future<Uint8List> receive() => _queue.next();

  // ---- IControlLink --------------------------------------------------------

  @override
  Stream<ControlInbound> get controlFrames => _controlController.stream;

  @override
  void sendControl(Map<String, dynamic> json) {
    _ws.sink.add(jsonEncode(json));
  }

  // -------------------------------------------------------------------------

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _ws.sink.close();
    _queue.close();
    if (!_controlController.isClosed) await _controlController.close();
  }
}

// ---------------------------------------------------------------------------

class _MsgQueue {
  final _buf = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];
  bool _closed = false;

  void add(Uint8List msg) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(msg);
    } else if (!_closed) {
      _buf.add(msg);
    }
  }

  void error(Object e) {
    for (final w in _waiters) {
      w.completeError(e);
    }
    _waiters.clear();
    _closed = true;
  }

  void close() {
    for (final w in _waiters) {
      w.completeError(const WsTransportError('transport closed'));
    }
    _waiters.clear();
    _closed = true;
  }

  Future<Uint8List> next() {
    if (_closed) {
      return Future.error(const WsTransportError('transport closed'));
    }
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future;
  }
}

// Decodes standard or url-safe base64 (pads defensively).
Uint8List _b64Decode(String s) {
  final pad = (4 - s.length % 4) % 4;
  final padded = s + '=' * pad;
  try {
    return base64.decode(padded);
  } on FormatException {
    return base64Url.decode(padded);
  }
}

// Relay registry uses standard base64 (from each peer's hello). QR/storage
// may carry url-safe encoding — re-encode to standard so the relay matches.
String _normalizeToStandard(String pubkey) {
  try {
    final pad = (4 - pubkey.length % 4) % 4;
    final bytes = base64Url.decode(pubkey + '=' * pad);
    return base64.encode(bytes);
  } catch (_) {
    return pubkey;
  }
}

bool _isErrorFrame(List<int> bytes) {
  try {
    final json = jsonDecode(utf8.decode(bytes));
    return json is Map && json['type'] == 'error';
  } catch (_) {
    return false;
  }
}

/// `https://…` → `wss://…` (and `http` → `ws`): endpoints are stored as
/// the address the pairing code named.
Uri _webSocketUri(String endpoint) {
  final uri = Uri.parse(endpoint);
  return uri.replace(scheme: uri.scheme == 'http' ? 'ws' : 'wss');
}
