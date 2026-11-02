import 'dart:convert';
import 'dart:io';

import 'package:app/data/transport/e2e.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture = jsonDecode(
    File('../.orchestration/contracts/e2e_v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  List<int> b64(String key) => base64.decode(fixture[key] as String);
  final room = fixture['room'] as String;
  final ts = DateTime.fromMillisecondsSinceEpoch(fixture['ts'] as int);
  final p2h = fixture['p2h'] as Map<String, dynamic>;
  final h2p = fixture['h2p'] as Map<String, dynamic>;

  test('Ed25519 public key maps to the same X25519 key as its seed', () async {
    final x = await X25519().newKeyPairFromSeed(
      await x25519PrivateFromEd25519Seed(b64('phone_seed')),
    );
    final fromSeed = (await x.extractPublicKey()).bytes;
    expect(x25519PublicFromEd25519(b64('phone_pk')), fromSeed);
    expect(base64.encode(fromSeed), fixture['phone_x25519_pk']);
  });

  test('derives the host fixture key from the phone side', () async {
    final key = await deriveSessionKey(
      selfSeed: b64('phone_seed'),
      selfPublic: b64('phone_pk'),
      peerPublic: b64('host_pk'),
    );
    expect(await key.extractBytes(), b64('session_key'));
  });

  test('seals byte-identical to the host and opens host frames', () async {
    final key = SecretKey(b64('session_key'));
    final box = base64.decode(p2h['box'] as String);
    final sealed = await seal(
      key,
      E2EDirection.phoneToHost,
      room,
      utf8.encode(p2h['plaintext'] as String),
      now: ts,
      nonce: base64.decode(p2h['nonce'] as String),
    );
    expect(sealed, box);

    final opened = await open(
      key,
      E2EDirection.hostToPhone,
      room,
      base64.decode(h2p['box'] as String),
    );
    expect(utf8.decode(opened.plaintext), h2p['plaintext']);
    expect(opened.sentAt, ts);
  });

  test('direction, room, and tampering are authenticated', () async {
    final key = SecretKey(b64('session_key'));
    final box = base64.decode(h2p['box'] as String);
    final tampered = [...box]..[20] ^= 1;
    for (final attempt in [
      () => open(key, E2EDirection.phoneToHost, room, box),
      () => open(key, E2EDirection.hostToPhone, 'other', box),
      () => open(key, E2EDirection.hostToPhone, room, tampered),
      () => open(key, E2EDirection.hostToPhone, room, utf8.encode('{}')),
    ]) {
      await expectLater(attempt(), throwsA(isA<E2EException>()));
    }
  });

  test('replay guard rejects stale and repeated frames', () async {
    final key = SecretKey(b64('session_key'));
    final opened = await open(
      key,
      E2EDirection.hostToPhone,
      room,
      base64.decode(h2p['box'] as String),
    );
    final guard = ReplayGuard(const Duration(seconds: 1));
    expect(guard.accept(opened, now: ts.add(const Duration(seconds: 2))), isFalse);
    expect(guard.accept(opened, now: ts), isTrue);
    expect(guard.accept(opened, now: ts), isFalse);
  });
}
