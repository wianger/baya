import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/transport/noise.dart';

/// Sends a request to the computer, about the session it was made for.
typedef SessionCall = Future<Json> Function(String method, Json params);

/// Bytes done and the total, as a transfer goes.
typedef TransferProgress = void Function(int done, int total);

/// What file transfers need of the connection to one computer: requests,
/// and file bytes as data frames both ways.
abstract class TransferLink {
  Future<Json> call(String method, Json params);
  Stream<DataFrame> get data;
  Future<void> sendData(int stream, int offset, List<int> bytes);

  /// `_baya/stream_end` and `_baya/upload_progress`.
  Stream<({String method, Json params})> get events;
}

/// [TransferLink] over a [HostConnection], about one session.
class HostTransferLink implements TransferLink {
  HostTransferLink(this.host, this.sessionId);

  final HostConnection host;
  final String sessionId;

  @override
  Future<Json> call(String method, Json params) => host.call(method, {
    'sessionId': sessionId,
    ...params,
  }, const Duration(minutes: 2));

  @override
  Stream<DataFrame> get data => host.data;

  @override
  Future<void> sendData(int stream, int offset, List<int> bytes) =>
      host.sendData(stream, offset, bytes);

  @override
  Stream<({String method, Json params})> get events => host.transferEvents;
}

/// A file on the phone; [read] starts at a byte, for a resumed upload.
class PhoneFile {
  const PhoneFile({required this.name, required this.size, required this.read});
  final String name;
  final int size;
  final Stream<List<int>> Function(int start) read;
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

/// The connection went away mid-transfer: carry on once it is back.
class _Interrupted implements Exception {
  const _Interrupted();
}

/// Files between the phone and the session's computer as binary data
/// frames over the encrypted connection. A transfer cut off (the phone
/// slept, the network changed) carries on from the byte it reached once the
/// computer answers again.
class FileTransfer {
  FileTransfer(
    this.link, {
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ],
    this.stall = const Duration(seconds: 30),
  });

  final TransferLink link;

  /// Waits between attempts to resume; when they run out, it fails.
  final List<Duration> retryDelays;

  /// No progress this long counts as cut off.
  final Duration stall;

  static const maxBytes = 100 * 1024 * 1024;

  /// Bytes sent ahead of what the computer has written.
  static const window = 4 * 1024 * 1024;

  /// The session's other requests (archives, conversions).
  SessionCall get call => link.call;

  static final _random = Random.secure();
  static int _streamId() => _random.nextInt(0x7fffffff) + 1;

  /// Runs [attempt] again after a cut-off until it finishes or the delays
  /// run out; anything else is final.
  Future<T> _resuming<T>(
    TransferControl? control,
    Future<T> Function() attempt,
  ) async {
    for (var i = 0; ; i++) {
      if (control?.cancelled ?? false) throw const TransferCancelled();
      try {
        return await attempt();
      } catch (error) {
        final cutOff =
            error is _Interrupted ||
            error is RpcClosed ||
            error is TimeoutException;
        if (!cutOff || i >= retryDelays.length) rethrow;
      }
      await Future<void>.delayed(retryDelays[i]);
    }
  }

  /// Sends [file] into [dir] on the computer, or the session's inbox
  /// (`.baya/uploads`) when null.
  Future<UploadedFile> upload(
    PhoneFile file, {
    String? dir,
    TransferProgress? onProgress,
    TransferControl? control,
  }) async {
    if (file.size > maxBytes) throw TransferTooLarge(file.size);
    String? uploadId;
    try {
      await _resuming(control, () async {
        final stream = _streamId();
        var acked = 0;
        String? failure;
        final acks = StreamController<void>.broadcast();
        final events = link.events.listen((event) {
          if (event.method != '_baya/upload_progress' ||
              event.params['uploadId'] != uploadId) {
            return;
          }
          failure = event.params['error'] as String?;
          acked = (event.params['received'] as num).toInt();
          acks.add(null);
        });
        try {
          if (uploadId == null) {
            final begun = await link.call('_baya/upload_begin', {
              'name': file.name,
              'size': file.size,
              'dir': ?dir,
              'stream': stream,
            });
            uploadId = begun['uploadId'] as String;
          } else {
            final back = await link.call('_baya/upload_resume', {
              'uploadId': uploadId,
              'stream': stream,
            });
            acked = (back['received'] as num).toInt();
          }
          onProgress?.call(acked, file.size);

          Future<void> waitFor(bool Function() ready) async {
            while (!ready()) {
              if (failure case final String failed) throw Exception(failed);
              if (control?.cancelled ?? false) {
                throw const TransferCancelled();
              }
              try {
                await acks.stream.first.timeout(stall);
              } on TimeoutException {
                throw const _Interrupted();
              }
            }
          }

          var offset = acked;
          final pending = BytesBuilder(copy: false);
          Future<void> flush() async {
            final piece = pending.takeBytes();
            await waitFor(() => offset - acked < window);
            try {
              await link.sendData(stream, offset, piece);
            } catch (_) {
              throw const _Interrupted();
            }
            offset += piece.length;
            onProgress?.call(offset, file.size);
          }

          await for (final chunk in file.read(acked)) {
            if (control?.cancelled ?? false) throw const TransferCancelled();
            final bytes = chunk is Uint8List
                ? chunk
                : Uint8List.fromList(chunk);
            var at = 0;
            while (at < bytes.length) {
              final take = min(dataPiece - pending.length, bytes.length - at);
              pending.add(Uint8List.sublistView(bytes, at, at + take));
              at += take;
              if (pending.length == dataPiece) await flush();
            }
          }
          if (pending.isNotEmpty) await flush();
          await waitFor(() => acked >= file.size);
        } finally {
          await events.cancel();
          await acks.close();
        }
      });
      if (control?.cancelled ?? false) throw const TransferCancelled();
      final done = await _resuming(
        control,
        () => link.call('_baya/upload_finish', {'uploadId': uploadId}),
      );
      return UploadedFile(
        name: done['name'] as String,
        path: done['path'] as String,
        size: (done['size'] as num).toInt(),
      );
    } catch (_) {
      final id = uploadId;
      if (id != null) {
        unawaited(
          link
              .call('_baya/upload_cancel', {'uploadId': id})
              .then((_) {}, onError: (_) {}),
        );
      }
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
    var written = 0;
    await _resuming(control, () async {
      final stream = _streamId();
      final ended = Completer<Json>();
      final moved = StreamController<void>.broadcast();
      var size = -1;
      final frames = link.data.listen((frame) {
        // A repeat after a resume, or a frame of another download.
        if (frame.stream != stream || frame.offset != written) return;
        sink.add(frame.bytes);
        written += frame.bytes.length;
        if (size >= 0) onProgress?.call(written, size);
        moved.add(null);
      });
      final events = link.events.listen((event) {
        if (event.method == '_baya/stream_end' &&
            event.params['stream'] == stream &&
            !ended.isCompleted) {
          ended.complete(event.params);
        }
      });
      try {
        final opened = await link.call('_baya/download_open', {
          'path': path,
          'offset': written,
          'stream': stream,
        });
        size = (opened['size'] as num).toInt();
        if (size > maxBytes) throw TransferTooLarge(size);
        onProgress?.call(written, size);
        while (!ended.isCompleted) {
          if (control?.cancelled ?? false) {
            unawaited(
              link
                  .call('_baya/stream_close', {'stream': stream})
                  .then((_) {}, onError: (_) {}),
            );
            throw const TransferCancelled();
          }
          try {
            await Future.any([moved.stream.first, ended.future]).timeout(stall);
          } on TimeoutException {
            throw const _Interrupted();
          }
        }
        final end = await ended.future;
        // Frames come before the end on the one ordered connection, so a
        // short count means the computer stopped early: carry on from there.
        if (written < size) throw const _Interrupted();
        if (end['error'] case final String error) throw Exception(error);
      } finally {
        await frames.cancel();
        await events.cancel();
        await moved.close();
      }
    });
    return written;
  }
}
