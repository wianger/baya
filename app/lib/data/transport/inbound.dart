// What a computer sends, decrypted and parsed off the UI isolate.
//
// ChaCha20-Poly1305 in Dart and JSON parsing cost real time on a phone: a
// long conversation's history or a large download is megabytes of both. A
// worker isolate takes over the receiving direction of the Noise session
// once the handshake is done, and hands back whole messages (already
// parsed) and file data, in the order they came.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transport/noise.dart';

class InboundWorker {
  InboundWorker._(this._isolate, this._results);

  final Isolate _isolate;
  final ReceivePort _results;
  SendPort? _frames;
  final _waiting = <Uint8List>[];
  bool _closed = false;

  /// Starts a worker that carries on [cipher]'s receiving direction.
  static Future<InboundWorker> start(
    CipherState cipher, {
    required void Function(Json message) onMessage,
    required void Function(DataFrame frame) onData,
    required void Function(Object error) onError,
  }) async {
    final exported = await cipher.export();
    if (exported == null) throw StateError('The handshake is not done.');
    final (key, nonce) = exported;
    final results = ReceivePort();
    final isolate = await Isolate.spawn(_main, (
      results.sendPort,
      key,
      nonce,
    ), debugName: 'baya-inbound');
    final worker = InboundWorker._(isolate, results);
    results.listen((Object? result) {
      if (worker._closed) return;
      switch (result) {
        case SendPort port:
          worker._frames = port;
          for (final frame in worker._waiting) {
            port.send(TransferableTypedData.fromList([frame]));
          }
          worker._waiting.clear();
        case Map<String, dynamic> message:
          onMessage(message);
        case (int stream, int offset, TransferableTypedData bytes):
          onData(DataFrame(stream, offset, bytes.materialize().asUint8List()));
        case String error:
          worker.close();
          onError(NoiseException(error));
      }
    });
    return worker;
  }

  /// A frame off the socket.
  void add(List<int> frame) {
    if (_closed) return;
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
    final port = _frames;
    if (port == null) {
      _waiting.add(bytes);
    } else {
      port.send(TransferableTypedData.fromList([bytes]));
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _results.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

void _main((SendPort, List<int>, int) setup) {
  final (out, key, nonce) = setup;
  final cipher = CipherState.resume(key, nonce);
  final reader = MessageReader();
  final frames = ReceivePort();
  out.send(frames.sendPort);
  // Counters must stay in step: one frame at a time, in order.
  var chain = Future<void>.value();
  var failed = false;
  frames.listen((Object? raw) {
    if (raw is! TransferableTypedData) return;
    final frame = raw.materialize().asUint8List();
    chain = chain.then((_) async {
      if (failed) return;
      try {
        final message = await reader.read(cipher, frame);
        switch (message) {
          case null:
            return;
          case DataFrame(:final stream, :final offset, :final bytes):
            out.send((stream, offset, TransferableTypedData.fromList([bytes])));
          case Uint8List bytes:
            final json = jsonDecode(utf8.decode(bytes));
            if (json is Map<String, dynamic>) out.send(json);
        }
      } catch (error) {
        failed = true;
        out.send('$error');
        frames.close();
      }
    });
  });
}
