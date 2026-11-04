import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/acp/json_rpc.dart';

/// Sends a request to the computer, about the session it was made for.
typedef SessionCall = Future<Json> Function(String method, Json params);

/// Bytes done and the total, as a transfer goes.
typedef TransferProgress = void Function(int done, int total);

/// A file on the phone, read when the upload starts.
class PhoneFile {
  const PhoneFile({required this.name, required this.size, required this.read});
  final String name;
  final int size;
  final Stream<List<int>> Function() read;
}

/// Where an upload landed on the computer.
class UploadedFile {
  const UploadedFile({
    required this.name,
    required this.path,
    required this.size,
  });
  final String name;
  final String path;
  final int size;
}

/// Lets the person stop a transfer between two pieces.
class TransferControl {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class TransferCancelled implements Exception {
  const TransferCancelled();
}

class TransferTooLarge implements Exception {
  const TransferTooLarge(this.size);
  final int size;
}

/// Files between the phone and the session's computer, a piece per request
/// (`_baya/upload_*`, `_baya/download`).
class FileTransfer {
  FileTransfer(this._call);

  final SessionCall _call;

  static const piece = 512 * 1024;
  static const maxBytes = 100 * 1024 * 1024;

  /// Sends [file] into [dir] on the computer, or the session's inbox
  /// (`.baya/uploads`) when null.
  Future<UploadedFile> upload(
    PhoneFile file, {
    String? dir,
    TransferProgress? onProgress,
    TransferControl? control,
  }) async {
    if (file.size > maxBytes) throw TransferTooLarge(file.size);
    final begun = await _call('_baya/upload_begin', {
      'name': file.name,
      'size': file.size,
      'dir': ?dir,
    });
    final id = begun['uploadId'] as String;
    var sent = 0;
    try {
      onProgress?.call(0, file.size);
      await for (final chunk in _pieces(file.read())) {
        if (control?.cancelled ?? false) throw const TransferCancelled();
        await _call('_baya/upload_chunk', {
          'uploadId': id,
          'offset': sent,
          'data': base64Encode(chunk),
        });
        sent += chunk.length;
        onProgress?.call(sent, file.size);
      }
      if (control?.cancelled ?? false) throw const TransferCancelled();
      final done = await _call('_baya/upload_finish', {'uploadId': id});
      return UploadedFile(
        name: done['name'] as String,
        path: done['path'] as String,
        size: (done['size'] as num).toInt(),
      );
    } catch (_) {
      unawaited(
        _call('_baya/upload_cancel', {
          'uploadId': id,
        }).then((_) {}, onError: (_) {}),
      );
      rethrow;
    }
  }

  /// Writes the computer's file at [path] to [sink]; returns its size.
  Future<int> download(
    String path,
    IOSink sink, {
    TransferProgress? onProgress,
    TransferControl? control,
  }) async {
    var offset = 0;
    int? size;
    while (true) {
      if (control?.cancelled ?? false) throw const TransferCancelled();
      final reply = await _call('_baya/download', {
        'path': path,
        'offset': offset,
        'length': piece,
      });
      final total = (reply['size'] as num).toInt();
      size ??= total;
      if (size > maxBytes) throw TransferTooLarge(size);
      final bytes = base64Decode(reply['data'] as String);
      sink.add(bytes);
      offset += bytes.length;
      // A file that grows meanwhile is read to the size it first had.
      final end = reply['eof'] == true || offset >= size || bytes.isEmpty;
      onProgress?.call(offset, end ? offset : size);
      if (end) return offset;
    }
  }

  /// The stream regrouped into [piece]-sized chunks.
  static Stream<Uint8List> _pieces(Stream<List<int>> source) async* {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in source) {
      buffer.add(chunk);
      while (buffer.length >= piece) {
        final all = buffer.takeBytes();
        yield Uint8List.sublistView(all, 0, piece);
        if (all.length > piece) buffer.add(Uint8List.sublistView(all, piece));
      }
    }
    if (buffer.isNotEmpty) yield buffer.takeBytes();
  }
}
