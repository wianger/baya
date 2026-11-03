import 'dart:convert';

import 'package:app/acp/json_rpc.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/qr_scanner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/acp_harness.dart';

final _qr = QrPairPayload(
  token: base64Url.encode(List.filled(16, 1)),
  epk: base64Url.encode(List.filled(32, 2)),
  name: 'studio (WSL)',
  endpoint: 'https://studio.tail.ts.net/baya-pair/wsl/direct',
);

Future<FakeHostSocket> _socket(FakeHost host) async => await host.connect(
  endpoint: _qr.endpoint,
  hostKey: _qr.epk,
  identity: await Ed25519().newKeyPair(),
) as FakeHostSocket;

void main() {
  test('a valid code saves the computer', () async {
    final host = FakeHost()
      ..handlers['_baya/pair'] = (params) => {'hostname': 'studio'};
    final storage = MemoryStorage();
    final result = await performPairing(
      qr: _qr,
      socket: await _socket(host),
      storage: storage,
      deviceName: 'Pixel',
    );
    expect(host.calls.single.params, {
      'token': _qr.token,
      'deviceName': 'Pixel',
    });
    expect(result.hostnameHint, 'studio');
    expect(storage.peers.single.name, 'studio (WSL)');
    expect(storage.peers.single.endpoint, _qr.endpoint);
  });

  test('a refused code says why', () async {
    final host = FakeHost()
      ..handlers['_baya/pair'] = (_) => throw const RpcError(
        -32000,
        'This pairing code has expired.',
        {'reason': 'token_expired'},
      );
    final storage = MemoryStorage();
    await expectLater(
      performPairing(
        qr: _qr,
        socket: await _socket(host),
        storage: storage,
        deviceName: 'Pixel',
      ),
      throwsA(
        isA<PairingError>().having((e) => e.code, 'code', 'token_expired'),
      ),
    );
    expect(storage.peers, isEmpty);
  });
}
