// End-to-end encryption between this phone and a paired Baya host.
//
// Mirror of host/src/transport/e2e.ts; both sides are pinned to the shared
// fixture in .orchestration/contracts/e2e_v2.json.
//
//   key = HKDF-SHA256(X25519(self, peer), salt = "baya-e2e-v2",
//                     info = min(edA, edB) || max(edA, edB))
//   box = 0xBE 0x02 || nonce(12) || ChaCha20-Poly1305(ts_ms(8) || json)
//   aad = "baya-e2e-v2|" + ("p2h" | "h2p")
//
// Anything in between (`tailscale serve`, a proxy) sees only ciphertext and
// cannot forge frames: it never holds either private key.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _label = 'baya-e2e-v2';
const _nonceBytes = 12;
const _tagBytes = 16;
const replayWindow = Duration(minutes: 5);
final _p = (BigInt.one << 255) - BigInt.from(19);

enum E2EDirection { phoneToHost, hostToPhone }

class E2EException implements Exception {
  final String message;
  const E2EException(this.message);
  @override
  String toString() => 'E2EException: $message';
}

class Opened {
  final Uint8List plaintext;
  final DateTime sentAt;
  final String nonce;
  const Opened(this.plaintext, this.sentAt, this.nonce);
}

bool isSealed(List<int> data) =>
    data.length >= 2 && data[0] == 0xBE && data[1] == 0x02;

/// X25519 private scalar for an Ed25519 seed (RFC 8032 §5.1.5).
Future<List<int>> x25519PrivateFromEd25519Seed(List<int> seed) async {
  final hash = await Sha512().hash(seed);
  return hash.bytes.sublist(0, 32);
}

/// Birational map from an Ed25519 public key to its X25519 u-coordinate.
Uint8List x25519PublicFromEd25519(List<int> publicKey) {
  if (publicKey.length != 32) {
    throw const E2EException('Ed25519 public keys are 32 bytes.');
  }
  final bytes = Uint8List.fromList(publicKey);
  bytes[31] &= 0x7f;
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    y = (y << 8) | BigInt.from(bytes[i]);
  }
  if (y >= _p) throw const E2EException('Invalid Ed25519 public key.');
  final denominator = (BigInt.one - y) % _p;
  if (denominator == BigInt.zero) {
    throw const E2EException('Invalid Ed25519 public key.');
  }
  var u = ((BigInt.one + y) * denominator.modInverse(_p)) % _p;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = (u & BigInt.from(0xff)).toInt();
    u >>= 8;
  }
  return out;
}

/// Shared ChaCha20-Poly1305 key for one (self, peer) pair.
Future<SecretKey> deriveSessionKey({
  required List<int> selfSeed,
  required List<int> selfPublic,
  required List<int> peerPublic,
}) async {
  final x25519 = X25519();
  final keyPair = await x25519.newKeyPairFromSeed(
    await x25519PrivateFromEd25519Seed(selfSeed),
  );
  final shared = await x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(
      x25519PublicFromEd25519(peerPublic),
      type: KeyPairType.x25519,
    ),
  );
  final sharedBytes = await shared.extractBytes();
  if (sharedBytes.every((b) => b == 0)) {
    throw const E2EException('Degenerate peer key.');
  }
  final selfFirst = _compare(selfPublic, peerPublic) <= 0;
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: utf8.encode(_label),
    info: [
      ...(selfFirst ? selfPublic : peerPublic),
      ...(selfFirst ? peerPublic : selfPublic),
    ],
  );
}

final _random = Random.secure();
final _aead = Chacha20.poly1305Aead();

Future<Uint8List> seal(
  SecretKey key,
  E2EDirection direction,
  List<int> plaintext, {
  DateTime? now,
  List<int>? nonce,
}) async {
  final body = Uint8List(8 + plaintext.length);
  ByteData.sublistView(body)
      .setUint64(0, (now ?? DateTime.now()).millisecondsSinceEpoch);
  body.setRange(8, body.length, plaintext);
  final n =
      nonce ?? List<int>.generate(_nonceBytes, (_) => _random.nextInt(256));
  final box = await _aead.encrypt(
    body,
    secretKey: key,
    nonce: n,
    aad: _aad(direction),
  );
  return Uint8List.fromList([
    0xBE,
    0x02,
    ...n,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}

Future<Opened> open(
  SecretKey key,
  E2EDirection direction,
  List<int> data,
) async {
  if (!isSealed(data) || data.length < 2 + _nonceBytes + 8 + _tagBytes) {
    throw const E2EException('Not an encrypted Baya frame.');
  }
  final nonce = data.sublist(2, 2 + _nonceBytes);
  final box = SecretBox(
    data.sublist(2 + _nonceBytes, data.length - _tagBytes),
    nonce: nonce,
    mac: Mac(data.sublist(data.length - _tagBytes)),
  );
  final List<int> body;
  try {
    body = await _aead.decrypt(box, secretKey: key, aad: _aad(direction));
  } on SecretBoxAuthenticationError {
    throw const E2EException('Frame failed authentication.');
  }
  final bytes = Uint8List.fromList(body);
  final sentAt = ByteData.sublistView(bytes).getUint64(0);
  return Opened(
    Uint8List.sublistView(bytes, 8),
    DateTime.fromMillisecondsSinceEpoch(sentAt),
    base64.encode(nonce),
  );
}

/// Rejects frames outside the replay window and nonces already seen in it.
class ReplayGuard {
  final Duration window;
  final _seen = <String, DateTime>{};
  ReplayGuard([this.window = replayWindow]);

  bool accept(Opened opened, {DateTime? now}) {
    final t = now ?? DateTime.now();
    if (t.difference(opened.sentAt).abs() > window) return false;
    _seen.removeWhere((_, at) => t.difference(at) > window * 2);
    if (_seen.containsKey(opened.nonce)) return false;
    _seen[opened.nonce] = t;
    return true;
  }
}

List<int> _aad(E2EDirection direction) => utf8.encode(
  '$_label|${direction == E2EDirection.phoneToHost ? 'p2h' : 'h2p'}',
);

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < min(a.length, b.length); i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
