import 'dart:async';
import 'dart:typed_data';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/data/transport/noise.dart';

/// A computer's side of the file transfer methods, in memory: uploads take
/// data frames and report progress, downloads stream frames then end. Set
/// [cutAfter] to drop the "connection" once that many bytes have gone by.
class FakeComputer implements TransferLink {
  final files = <String, List<int>>{};
  final calls = <String>[];
  final _data = StreamController<DataFrame>.broadcast(sync: true);
  final _events = StreamController<({String method, Json params})>.broadcast(
    sync: true,
  );
  final _uploads = <String, ({String name, int size, BytesBuilder bytes})>{};
  final _streams = <int, String>{};
  var _next = 0;

  /// Bytes moved (either way) after which the connection drops once.
  int? cutAfter;
  var _moved = 0;
  bool _down = false;

  /// Other methods (archives, conversions), answered by the test.
  Future<Json> Function(String method, Json params)? other;

  void _count(int bytes) {
    _moved += bytes;
    final cut = cutAfter;
    if (cut != null && _moved >= cut) {
      cutAfter = null;
      _down = true;
      // Back a moment later, as a phone reconnecting would find it.
      Timer(const Duration(milliseconds: 20), () => _down = false);
    }
  }

  @override
  Stream<DataFrame> get data => _data.stream;

  @override
  Stream<({String method, Json params})> get events => _events.stream;

  @override
  Future<void> sendData(int stream, int offset, List<int> bytes) async {
    if (_down) throw const RpcClosed('offline');
    final id = _streams[stream];
    if (id == null) return;
    final upload = _uploads[id]!;
    if (offset != upload.bytes.length) return;
    upload.bytes.add(bytes);
    _count(bytes.length);
    if (_down) return; // Lost on the way.
    scheduleMicrotask(
      () => _events.add((
        method: '_baya/upload_progress',
        params: {'uploadId': id, 'received': upload.bytes.length},
      )),
    );
  }

  @override
  Future<Json> call(String method, Json params) async {
    calls.add(method);
    if (_down) throw const RpcClosed('offline');
    switch (method) {
      case '_baya/upload_begin':
        final id = 'u${_next++}';
        _uploads[id] = (
          name: params['name'] as String,
          size: params['size'] as int,
          bytes: BytesBuilder(),
        );
        _streams[params['stream'] as int] = id;
        return {'uploadId': id, 'dir': params['dir'] ?? '/w/.baya/uploads'};
      case '_baya/upload_resume':
        final id = params['uploadId'] as String;
        _streams[params['stream'] as int] = id;
        return {'received': _uploads[id]!.bytes.length};
      case '_baya/upload_finish':
        final id = params['uploadId'] as String;
        final upload = _uploads.remove(id)!;
        if (upload.bytes.length != upload.size) {
          throw RpcError(-32603, 'Only ${upload.bytes.length} bytes arrived.');
        }
        files['/w/${upload.name}'] = upload.bytes.takeBytes();
        return {
          'name': upload.name,
          'path': '/w/${upload.name}',
          'size': upload.size,
        };
      case '_baya/upload_cancel':
        _uploads.remove(params['uploadId']);
        return {};
      case '_baya/download_open':
        final bytes = files[params['path']]!;
        final stream = params['stream'] as int;
        var offset = params['offset'] as int;
        scheduleMicrotask(() {
          while (offset < bytes.length) {
            if (_down) return; // The phone hears nothing more.
            final end = (offset + dataPiece).clamp(0, bytes.length);
            _data.add(
              DataFrame(
                stream,
                offset,
                Uint8List.fromList(bytes.sublist(offset, end)),
              ),
            );
            _count(end - offset);
            offset = end;
          }
          _events.add((
            method: '_baya/stream_end',
            params: {'stream': stream, 'size': bytes.length, 'sent': offset},
          ));
        });
        return {'name': 'x', 'size': bytes.length};
      case '_baya/stream_close':
        return {};
    }
    final answer = other;
    if (answer != null) return answer(method, params);
    throw StateError(method);
  }
}
