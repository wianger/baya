import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transfer/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The host's side of `_baya/upload_*` and `_baya/download`, in memory.
class FakeComputer {
  final files = <String, List<int>>{};
  final calls = <String>[];
  final _open = <String, (String, int, BytesBuilder)>{};
  var _next = 0;

  Future<Json> call(String method, Json params) async {
    calls.add(method);
    switch (method) {
      case '_baya/upload_begin':
        final id = 'u${_next++}';
        _open[id] = (
          params['name'] as String,
          params['size'] as int,
          BytesBuilder(),
        );
        return {'uploadId': id, 'dir': params['dir'] ?? '/w/.baya/uploads'};
      case '_baya/upload_chunk':
        final (_, _, bytes) = _open[params['uploadId']]!;
        expect(params['offset'], bytes.length);
        bytes.add(base64Decode(params['data'] as String));
        return {'received': bytes.length};
      case '_baya/upload_finish':
        final (name, size, bytes) = _open.remove(params['uploadId'])!;
        expect(bytes.length, size);
        files['/w/$name'] = bytes.takeBytes();
        return {'name': name, 'path': '/w/$name', 'size': size};
      case '_baya/upload_cancel':
        _open.remove(params['uploadId']);
        return {};
      case '_baya/download':
        final data = files[params['path']]!;
        final offset = params['offset'] as int;
        final end = (offset + (params['length'] as int)).clamp(0, data.length);
        return {
          'name': 'x',
          'size': data.length,
          'offset': offset,
          'data': base64Encode(data.sublist(offset, end)),
          'eof': end >= data.length,
        };
    }
    throw StateError(method);
  }
}

List<int> bytes(int length) => List.generate(length, (i) => i % 251);

void main() {
  test('a phone file goes over in pieces and comes back the same', () async {
    final computer = FakeComputer();
    final transfer = FileTransfer(computer.call);
    final content = bytes(FileTransfer.piece * 2 + 1234);
    final progress = <int>[];
    final sent = await transfer.upload(
      PhoneFile(
        name: 'big.bin',
        size: content.length,
        // Odd-sized reads, regrouped into pieces.
        read: () => Stream.fromIterable([
          for (var i = 0; i < content.length; i += 70000)
            content.sublist(i, (i + 70000).clamp(0, content.length)),
        ]),
      ),
      onProgress: (done, _) => progress.add(done),
    );
    expect(sent.path, '/w/big.bin');
    expect(
      computer.calls.where((c) => c == '_baya/upload_chunk'),
      hasLength(3),
    );
    expect(progress.last, content.length);

    final out = File(
      '${Directory.systemTemp.createTempSync('baya-dl').path}/big.bin',
    );
    final sink = out.openWrite();
    final size = await transfer.download('/w/big.bin', sink);
    await sink.close();
    expect(size, content.length);
    expect(out.readAsBytesSync(), content);
  });

  test('an empty file and a cancelled one', () async {
    final computer = FakeComputer();
    final transfer = FileTransfer(computer.call);
    final empty = await transfer.upload(
      PhoneFile(name: 'e', size: 0, read: () => const Stream.empty()),
    );
    expect(empty.size, 0);

    final control = TransferControl()..cancel();
    await expectLater(
      transfer.upload(
        PhoneFile(name: 'c', size: 3, read: () => Stream.value([1, 2, 3])),
        control: control,
      ),
      throwsA(isA<TransferCancelled>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(computer.calls.last, '_baya/upload_cancel');
  });

  test('too large never starts', () async {
    final computer = FakeComputer();
    await expectLater(
      FileTransfer(computer.call).upload(
        PhoneFile(
          name: 'huge',
          size: FileTransfer.maxBytes + 1,
          read: () => const Stream.empty(),
        ),
      ),
      throwsA(isA<TransferTooLarge>()),
    );
    expect(computer.calls, isEmpty);
  });
}
