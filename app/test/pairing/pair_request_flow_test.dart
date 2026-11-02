import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/qr_scanner.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Q {
  final _buf = <Uint8List>[];
  final _wait = <Completer<Uint8List>>[];
  void add(Uint8List d) {
    if (_wait.isNotEmpty) {
      _wait.removeAt(0).complete(d);
    } else {
      _buf.add(d);
    }
  }

  Future<Uint8List> next() {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    final c = Completer<Uint8List>();
    _wait.add(c);
    return c.future;
  }
}

class _MemTransport implements PeerTransport {
  final _Q _s;
  final _Q _r;
  _MemTransport({required _Q send, required _Q recv}) : _s = send, _r = recv;
  @override
  Future<void> send(Uint8List d) async => _s.add(d);
  @override
  Future<Uint8List> receive() => _r.next();
  @override
  Future<void> close() async {}
}

class _FakeStorage extends PairingStorage {
  final List<PeerRecord> saved = [];

  @override
  Future<List<PeerRecord>> listPeers() async => saved;

  @override
  Future<void> savePeer(PeerRecord r) async => saved.add(r);
}

const _qr = QrPairPayload(
  token: 'AAAAAAAAAAAAAAAAAAAAAA',
  epk: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  sessionName: 'Pi',
  roomId: 'room-from-qr',
  relayUrl: 'https://relay.example',
);

void main() {
  test('pair_ok is persisted with its room and the QR relay', () async {
    final q1 = _Q();
    final q2 = _Q();
    final host = _MemTransport(send: q1, recv: q2);
    final app = _MemTransport(send: q2, recv: q1);
    final storage = _FakeStorage();

    unawaited(() async {
      final raw = await host.receive();
      final req = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      expect(req['type'], 'pair_request');
      expect(req['token'], _qr.token);
      await host.send(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'pair_ok',
              'in_reply_to': req['id'],
              'session_name': 'Review',
              'session_started_at': 1700000000000,
              'room_id': 'room-from-pair-ok',
              'hostname': 'workstation',
            }),
          ),
        ),
      );
    }());

    final result = await performPairing(
      qr: _qr,
      transport: app,
      storage: storage,
      deviceName: 'phone',
    );
    expect(result.peer.sessionName, 'Review');
    expect(result.peer.roomId, 'room-from-pair-ok');
    expect(result.peer.relayUrl, 'https://relay.example');
    expect(result.hostnameHint, 'workstation');
    expect(storage.saved.single.roomId, 'room-from-pair-ok');
  });

  test('pair_error surfaces as a PairingError', () async {
    final q1 = _Q();
    final q2 = _Q();
    final host = _MemTransport(send: q1, recv: q2);
    final app = _MemTransport(send: q2, recv: q1);

    unawaited(() async {
      final raw = await host.receive();
      final req = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      await host.send(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'pair_error',
              'in_reply_to': req['id'],
              'code': 'token_expired',
              'message': 'expired',
            }),
          ),
        ),
      );
    }());

    await expectLater(
      performPairing(
        qr: _qr,
        transport: app,
        storage: _FakeStorage(),
        deviceName: 'phone',
      ),
      throwsA(
        isA<PairingError>().having((e) => e.code, 'code', 'token_expired'),
      ),
    );
  });
}
