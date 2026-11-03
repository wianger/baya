// The phone's end of one computer's WebSocket.
//
//   1. Connect to the host's `…/direct` address (through `tailscale serve`).
//   2. Noise IK handshake (see noise.dart): the phone knows the computer's key
//      from the pairing code, sends its own Ed25519 identity in the first
//      payload, and both sides end up with fresh transport keys.
//   3. Every frame after that is a Noise transport message carrying (a piece
//      of) one JSON-RPC message.

import 'dart:async';
import 'dart:convert';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transport/noise.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Close codes the host uses.
abstract final class HostClose {
  static const noise = 4002;
  static const unpaired = 4003;
}

/// The prologue both sides bind into the handshake.
final noisePrologue = ascii.encode('baya/1');

class SocketClosed {
  final int? code;
  final String? reason;
  const SocketClosed(this.code, this.reason);
}

/// An encrypted, authenticated JSON message pipe to one computer.
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
  WsHostSocket._(this._ws, this._session);

  final WebSocketChannel _ws;
  final NoiseSession _session;
  final _reader = MessageReader();
  final _messages = StreamController<Json>.broadcast();
  final _closed = Completer<SocketClosed>();
  // Encryption is async and counters must stay in order: one chain each way.
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
    final reply = Completer<List<int>>();
    WsHostSocket? socket;
    final pending = <List<int>>[];
    ws.stream.listen(
      (raw) {
        if (raw is! List<int>) return;
        if (!reply.isCompleted) {
          reply.complete(raw);
        } else if (socket == null) {
          pending.add(raw);
        } else {
          socket._receive(raw);
        }
      },
      onError: (Object error) {
        if (!reply.isCompleted) reply.completeError(error);
      },
      onDone: () {
        if (!reply.isCompleted) {
          reply.completeError(
            const RpcClosed('The computer closed the connection.'),
          );
        }
        socket?._finish(SocketClosed(ws.closeCode, ws.closeReason));
      },
    );

    try {
      await ws.ready;
      final edPublic = (await identity.extractPublicKey()).bytes;
      final initiator = await NoiseInitiator.create(
        prologue: noisePrologue,
        staticKey: await x25519KeyPair(
          await x25519FromEd25519Seed(await identity.extractPrivateKeyBytes()),
        ),
        remoteStatic: x25519PublicFromEd25519(decodeKey(hostKey)),
      );
      ws.sink.add(
        await initiator.writeMessage(
          utf8.encode(jsonEncode({'ed25519': base64.encode(edPublic)})),
        ),
      );
      final (_, session) = await initiator.readMessage(await reply.future);
      final ready = WsHostSocket._(ws, session);
      socket = ready;
      for (final frame in pending) {
        ready._receive(frame);
      }
      return ready;
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
          for (final frame in await sealMessage(_session.send, plaintext)) {
            if (_closed.isCompleted) return;
            _ws.sink.add(frame);
          }
        })
        .catchError((Object error) => debugPrint('[host] send failed: $error'));
  }

  void _receive(List<int> frame) {
    _inbound = _inbound
        .then((_) async {
          final message = await _reader.read(_session.receive, frame);
          if (message == null) return;
          final json = jsonDecode(utf8.decode(message));
          if (json is Map && !_messages.isClosed) {
            _messages.add(json.cast<String, dynamic>());
          }
        })
        .catchError((Object error) async {
          // Counters are out of step after a bad frame: end the connection.
          debugPrint('[host] frame rejected: $error');
          await close();
        });
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
