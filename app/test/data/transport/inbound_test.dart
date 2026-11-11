import 'dart:async';
import 'dart:convert';

import 'package:app/data/transport/inbound.dart';
import 'package:app/data/transport/noise.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = List<int>.generate(32, (i) => i);

  test('messages and file data come back parsed, in order', () async {
    // The computer's side of the direction the worker takes over, a few
    // messages in, as after a handshake and some traffic.
    final host = CipherState()..initialize(key);
    final phone = CipherState()..initialize(key);
    for (var i = 0; i < 3; i++) {
      await phone.decrypt(const [], await host.encrypt(const [], [1]));
    }

    final got = <Object>[];
    final errors = <Object>[];
    final done = Completer<void>();
    final worker = await InboundWorker.start(
      phone,
      onMessage: (message) {
        got.add(message);
        if (message['id'] == 'last') done.complete();
      },
      onData: got.add,
      onError: errors.add,
    );
    addTearDown(worker.close);

    final big = 'x' * (maxPiece * 2 + 10);
    for (final frame in [
      ...await sealMessage(
        host,
        utf8.encode(jsonEncode({'id': 1, 'text': big})),
      ),
      await sealData(host, 7, 64000, [1, 2, 3]),
      ...await sealMessage(host, utf8.encode(jsonEncode({'id': 'last'}))),
    ]) {
      worker.add(frame);
    }
    await done.future.timeout(const Duration(seconds: 10));

    expect(errors, isEmpty);
    expect(got, hasLength(3));
    expect((got[0] as Map)['text'], big);
    final data = got[1] as DataFrame;
    expect((data.stream, data.offset), (7, 64000));
    expect(data.bytes, [1, 2, 3]);
    expect(got[2], {'id': 'last'});
  });

  test('a frame that fails authentication is an error, and the end', () async {
    final host = CipherState()..initialize(key);
    final phone = CipherState()..initialize(key);
    final failed = Completer<Object>();
    final got = <Object>[];
    final worker = await InboundWorker.start(
      phone,
      onMessage: got.add,
      onData: got.add,
      onError: failed.complete,
    );
    addTearDown(worker.close);
    final frame = (await sealMessage(host, utf8.encode('{"id":1}'))).single;
    frame[frame.length - 1] ^= 1;
    worker.add(frame);
    worker.add((await sealMessage(host, utf8.encode('{"id":2}'))).single);
    expect(
      await failed.future.timeout(const Duration(seconds: 10)),
      isA<NoiseException>(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(got, isEmpty);
  });
}
