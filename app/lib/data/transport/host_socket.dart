// The phone's end of one computer's WebSocket.
//
//   1. Connect to the host's `…/direct` address (through `tailscale serve`).
//   2. Prove this phone's Ed25519 key: hello → challenge → auth (JSON text).
//   3. From then on every frame is binary: one sealed JSON-RPC message
//      (see e2e.dart), so nothing in between can read or forge it.

import 'dart:async';
import 'dart:convert';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transport/e2e.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Close codes the host uses.
abstract final class HostClose {
  static const clockSkew = 4001;
  static const unpaired = 4003;
}

class SocketClosed {
  final int? code;
  final String? reason;
  const SocketClosed(this.code, this.reason);

  /// Minutes the phone's clock is off, when the host closed for that.
  int? get clockSkewMinutes => code == HostClose.clockSkew
      ? int.tryParse((reason ?? '').split(':').last)
      : null;
}

/// A sealed, authenticated JSON message pipe to one computer.
abstract class HostSocket {
  Stream<Json> get messages;
  void send(Json message);

  /// Completes when the socket closes, with the host's code and reason.
  Future<SocketClosed> get closed;
  Future<void> close();
}

typedef HostSocketFactory = Future<HostSocket> Function({
  required String endpoint,
  required String hostKey,
  required SimpleKeyPair identity,
});

class WsHostSocket implements HostSocket {
  WsHostSocket._(this._ws, this._key);

  final WebSocketChannel _ws;
  final SecretKey _key;
  final _messages = StreamController<Json>.broadcast();
  final _closed = Completer<SocketClosed>();
  final _replay = ReplayGuard();
  // Sealing is async; these chains keep frames in wire order.
  Future<void> _inbound = Future.value();
  Future<void> _outbound = Future.value();

  static Future<HostSocket> connect({
    required String endpoint,
    required String hostKey,
    required SimpleKeyPair identity,
  }) async {
    final ws = IOWebSocketChannel.connect(
      _webSocketUri(endpoint),
      pingInterval: const Duration(seconds: 20),
    );
    final publicKey = await identity.extractPublicKey();
    final key = await deriveSessionKey(
      selfSeed: await identity.extractPrivateKeyBytes(),
      selfPublic: publicKey.bytes,
      peerPublic: decodeKey(hostKey),
    );
    final socket = WsHostSocket._(ws, key);
    final challenge = Completer<Json>();
    var authenticated = false;

    ws.stream.listen(
      (raw) {
        if (!authenticated) {
          if (challenge.isCompleted) return;
          try {
            challenge.complete(
              (jsonDecode(raw as String) as Map).cast<String, dynamic>(),
            );
          } catch (error) {
            challenge.completeError(error);
          }
          return;
        }
        if (raw is List<int>) socket._receive(Uint8List.fromList(raw));
      },
      onError: (Object error) {
        if (!challenge.isCompleted) challenge.completeError(error);
      },
      onDone: () {
        if (!challenge.isCompleted) {
          challenge.completeError(
            const RpcClosed('The computer closed the connection.'),
          );
        }
        socket._finish(SocketClosed(ws.closeCode, ws.closeReason));
      },
    );

    try {
      await ws.ready;
      ws.sink.add(
        jsonEncode({'type': 'hello', 'pubkey': base64.encode(publicKey.bytes)}),
      );
      final frame = await challenge.future;
      if (frame['type'] != 'challenge') {
        throw const RpcClosed('The computer did not send a challenge.');
      }
      final nonce = decodeKey(frame['nonce'] as String);
      final signature = await Ed25519().sign(nonce, keyPair: identity);
      ws.sink.add(
        jsonEncode({'type': 'auth', 'sig': base64.encode(signature.bytes)}),
      );
      authenticated = true;
      return socket;
    } catch (_) {
      await ws.sink.close();
      rethrow;
    }
  }

  @override
  Stream<Json> get messages => _messages.stream;

  @override
  Future<SocketClosed> get closed => _closed.future;

  @override
  void send(Json message) {
    final plaintext = utf8.encode(jsonEncode(message));
    _outbound = _outbound
        .then((_) async {
          final box = await seal(_key, E2EDirection.phoneToHost, plaintext);
          if (!_closed.isCompleted) _ws.sink.add(box);
        })
        .catchError((Object error) => debugPrint('[host] seal failed: $error'));
  }

  void _receive(Uint8List bytes) {
    _inbound = _inbound
        .then((_) async {
          final opened = await open(_key, E2EDirection.hostToPhone, bytes);
          if (!_replay.accept(opened)) return;
          final message = jsonDecode(utf8.decode(opened.plaintext));
          if (message is Map && !_messages.isClosed) {
            _messages.add(message.cast<String, dynamic>());
          }
        })
        .catchError(
          (Object error) => debugPrint('[host] frame dropped: $error'),
        );
  }

  void _finish(SocketClosed closed) {
    if (!_closed.isCompleted) _closed.complete(closed);
    unawaited(_messages.close());
  }

  @override
  Future<void> close() async {
    await _ws.sink.close();
    _finish(const SocketClosed(null, null));
  }
}

/// Standard or URL-safe base64, padded or not.
Uint8List decodeKey(String value) {
  final padded = value + '=' * ((4 - value.length % 4) % 4);
  try {
    return base64.decode(padded);
  } on FormatException {
    return base64Url.decode(padded);
  }
}

/// `https://…` → `wss://…`: endpoints are stored as the pairing code named them.
Uri _webSocketUri(String endpoint) {
  final uri = Uri.parse(endpoint);
  return uri.replace(
    scheme: uri.scheme == 'http' || uri.scheme == 'ws' ? 'ws' : 'wss',
  );
}
