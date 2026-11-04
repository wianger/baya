import 'dart:io';

import 'package:app/data/transfer/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transfer.dart';

List<int> bytes(int length) => List.generate(length, (i) => i % 251);

FileTransfer quick(FakeComputer computer) => FileTransfer(
  computer,
  retryDelays: const [
    Duration(milliseconds: 30),
    Duration(milliseconds: 30),
    Duration(milliseconds: 30),
  ],
  stall: const Duration(milliseconds: 200),
);

PhoneFile phoneFile(String name, List<int> content) => PhoneFile(
  name: name,
  size: content.length,
  // Odd-sized reads, as a file picker gives them.
  read: (start) => Stream.fromIterable([
    for (var i = start; i < content.length; i += 70000)
      content.sublist(i, (i + 70000).clamp(0, content.length)),
  ]),
);

Future<List<int>> fetch(FileTransfer transfer, String path) async {
  final out = File(
    '${Directory.systemTemp.createTempSync('baya-dl').path}/out.bin',
  );
  final sink = out.openWrite();
  await transfer.download(path, sink);
  await sink.close();
  return out.readAsBytesSync();
}

void main() {
  test(
    'a phone file goes over as data frames and comes back the same',
    () async {
      final computer = FakeComputer();
      final transfer = quick(computer);
      final content = bytes(300 * 1000 + 1234);
      final progress = <int>[];
      final sent = await transfer.upload(
        phoneFile('big.bin', content),
        onProgress: (done, _) => progress.add(done),
      );
      expect(sent.path, '/w/big.bin');
      expect(computer.files['/w/big.bin'], content);
      expect(progress.last, content.length);
      expect(computer.calls, ['_baya/upload_begin', '_baya/upload_finish']);
      expect(await fetch(transfer, '/w/big.bin'), content);
    },
  );

  test('an upload cut off half way carries on from where it got', () async {
    final computer = FakeComputer()..cutAfter = 150 * 1000;
    final content = bytes(400 * 1000);
    final sent = await quick(computer).upload(phoneFile('cut.bin', content));
    expect(computer.files['/w/${sent.name}'], content);
    expect(computer.calls, contains('_baya/upload_resume'));
    expect(
      computer.calls.where((c) => c == '_baya/upload_begin'),
      hasLength(1),
    );
  });

  test('a download cut off half way carries on from where it got', () async {
    final computer = FakeComputer();
    final content = bytes(500 * 1000);
    computer.files['/w/movie.mp4'] = content;
    computer.cutAfter = 200 * 1000;
    expect(await fetch(quick(computer), '/w/movie.mp4'), content);
    expect(
      computer.calls.where((c) => c == '_baya/download_open'),
      hasLength(2),
    );
  });

  test('an empty file, a cancelled one and a too large one', () async {
    final computer = FakeComputer();
    final transfer = quick(computer);
    final empty = await transfer.upload(phoneFile('e', const []));
    expect(empty.size, 0);

    await expectLater(
      transfer.upload(
        phoneFile('c', [1, 2, 3]),
        control: TransferControl()..cancel(),
      ),
      throwsA(isA<TransferCancelled>()),
    );

    final before = computer.calls.length;
    await expectLater(
      transfer.upload(
        PhoneFile(
          name: 'huge',
          size: FileTransfer.maxBytes + 1,
          read: (_) => const Stream.empty(),
        ),
      ),
      throwsA(isA<TransferTooLarge>()),
    );
    expect(computer.calls.length, before);
  });
}
