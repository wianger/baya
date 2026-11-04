import 'dart:async';
import 'dart:io';

import 'package:app/data/transport/host_socket.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an unreachable computer fails the connect, and nothing else', () async {
    final identity = await Ed25519().newKeyPair();
    // A port nothing listens on: refused before any handshake.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();

    final stray = <Object>[];
    Object? failure;
    await runZonedGuarded(() async {
      try {
        await WsHostSocket.connect(
          endpoint: 'http://127.0.0.1:$port/baya-pair/wsl/direct',
          hostKey: 'UlAGJ+qrhMT+1t8xHBV3qyy8zKeri9edt8ckcmhtozE=',
          identity: identity,
        );
      } catch (error) {
        failure = error;
      }
      // Let any error left behind surface.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }, (error, _) => stray.add(error));

    expect(failure, isNotNull);
    expect(stray, isEmpty, reason: 'errors nobody handled: $stray');
  });
}
