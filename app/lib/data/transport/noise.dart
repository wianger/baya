// The Noise Protocol Framework (revision 34), the pattern Baya uses:
//
//   Noise_IK_25519_ChaChaPoly_SHA256
//     <- s
//     ...
//     -> e, es, s, ss
//     <- e, ee, se
//
// Mirror of host/src/transport/noise.ts; both are pinned to the cacophony
// vector and to the Baya handshake vector in .orchestration/contracts/.
// The phone knows the computer's static key from the pairing code, so one
// round trip authenticates both sides, and ephemeral keys give forward
// secrecy.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const noiseProtocolName = 'Noise_IK_25519_ChaChaPoly_SHA256';
const _dhLen = 32;
const _tagLen = 16;

/// The largest Noise message, tag included.
const maxNoiseMessage = 65535;

/// The largest piece of a message per frame (flag byte and tag excluded).
const maxPiece = maxNoiseMessage - _tagLen - 1;

final _p = (BigInt.one << 255) - BigInt.from(19);
final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();
final _sha256 = Sha256();
final _hmac = Hmac.sha256();

class NoiseException implements Exception {
  final String message;
  const NoiseException(this.message);

  @override
  String toString() => 'NoiseException: $message';
}

Future<List<int>> _hash(List<List<int>> parts) async =>
    (await _sha256.hash([for (final part in parts) ...part])).bytes;

Future<List<int>> _mac(List<int> key, List<List<int>> parts) async =>
    (await _hmac.calculateMac([
      for (final part in parts) ...part,
    ], secretKey: SecretKey(key))).bytes;

Future<(List<int>, List<int>)> _hkdf(
  List<int> chainingKey,
  List<int> input,
) async {
  final temp = await _mac(chainingKey, [input]);
  final first = await _mac(temp, [
    [1],
  ]);
  final second = await _mac(temp, [
    first,
    [2],
  ]);
  return (first, second);
}

Future<List<int>> _dh(SimpleKeyPair own, List<int> remotePublic) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: own,
    remotePublicKey: SimplePublicKey(remotePublic, type: KeyPairType.x25519),
  );
  final bytes = await shared.extractBytes();
  if (bytes.every((b) => b == 0)) {
    throw const NoiseException('Invalid public key.');
  }
  return bytes;
}

/// An X25519 key pair from its 32-byte private key.
Future<SimpleKeyPair> x25519KeyPair(List<int> privateKey) =>
    _x25519.newKeyPairFromSeed(privateKey);

/// One direction of transport: a key and a 64-bit message counter.
class CipherState {
  SecretKey? _key;
  int _nonce = 0;

  void initialize(List<int>? key) {
    _key = key == null ? null : SecretKey(key);
    _nonce = 0;
  }

  List<int> _iv() {
    final iv = Uint8List(12);
    ByteData.sublistView(iv).setUint64(4, _nonce, Endian.little);
    return iv;
  }

  Future<List<int>> encrypt(List<int> ad, List<int> plaintext) async {
    final key = _key;
    if (key == null) return plaintext;
    final box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: _iv(),
      aad: ad,
    );
    _nonce++;
    return [...box.cipherText, ...box.mac.bytes];
  }

  Future<List<int>> decrypt(List<int> ad, List<int> ciphertext) async {
    final key = _key;
    if (key == null) return ciphertext;
    if (ciphertext.length < _tagLen) {
      throw const NoiseException('Message too short.');
    }
    final box = SecretBox(
      ciphertext.sublist(0, ciphertext.length - _tagLen),
      nonce: _iv(),
      mac: Mac(ciphertext.sublist(ciphertext.length - _tagLen)),
    );
    final List<int> plaintext;
    try {
      plaintext = await _aead.decrypt(box, secretKey: key, aad: ad);
    } on SecretBoxAuthenticationError {
      throw const NoiseException('Message failed authentication.');
    }
    _nonce++;
    return plaintext;
  }
}

class _SymmetricState {
  late List<int> _chainingKey;
  late List<int> hash;
  final _cipher = CipherState();

  Future<void> initialize(String protocolName) async {
    final name = protocolName.codeUnits;
    hash = name.length <= 32
        ? [...name, ...List.filled(32 - name.length, 0)]
        : await _hash([name]);
    _chainingKey = hash;
  }

  Future<void> mixKey(List<int> input) async {
    final (chainingKey, key) = await _hkdf(_chainingKey, input);
    _chainingKey = chainingKey;
    _cipher.initialize(key);
  }

  Future<void> mixHash(List<int> data) async =>
      hash = await _hash([hash, data]);

  Future<List<int>> encryptAndHash(List<int> plaintext) async {
    final ciphertext = await _cipher.encrypt(hash, plaintext);
    await mixHash(ciphertext);
    return ciphertext;
  }

  Future<List<int>> decryptAndHash(List<int> ciphertext) async {
    final plaintext = await _cipher.decrypt(hash, ciphertext);
    await mixHash(ciphertext);
    return plaintext;
  }

  Future<(CipherState, CipherState)> split() async {
    final (first, second) = await _hkdf(_chainingKey, const []);
    return (
      CipherState()..initialize(first),
      CipherState()..initialize(second),
    );
  }
}

class NoiseSession {
  final CipherState send;
  final CipherState receive;
  final List<int> handshakeHash;
  const NoiseSession(this.send, this.receive, this.handshakeHash);
}

/// The phone's side of the IK handshake.
class NoiseInitiator {
  NoiseInitiator._(this._s, this._rs, this._e);

  final SimpleKeyPair _s;
  final List<int> _rs;
  final SimpleKeyPair _e;
  final _state = _SymmetricState();

  static Future<NoiseInitiator> create({
    required List<int> prologue,
    required SimpleKeyPair staticKey,
    required List<int> remoteStatic,
    SimpleKeyPair? ephemeral,
  }) async {
    final initiator = NoiseInitiator._(
      staticKey,
      remoteStatic,
      ephemeral ?? await _x25519.newKeyPair(),
    );
    await initiator._state.initialize(noiseProtocolName);
    await initiator._state.mixHash(prologue);
    await initiator._state.mixHash(remoteStatic);
    return initiator;
  }

  /// -> e, es, s, ss
  Future<Uint8List> writeMessage(List<int> payload) async {
    final e = (await _e.extractPublicKey()).bytes;
    final s = (await _s.extractPublicKey()).bytes;
    await _state.mixHash(e);
    await _state.mixKey(await _dh(_e, _rs));
    final encryptedStatic = await _state.encryptAndHash(s);
    await _state.mixKey(await _dh(_s, _rs));
    return Uint8List.fromList([
      ...e,
      ...encryptedStatic,
      ...await _state.encryptAndHash(payload),
    ]);
  }

  /// <- e, ee, se
  Future<(List<int>, NoiseSession)> readMessage(List<int> message) async {
    if (message.length < _dhLen + _tagLen) {
      throw const NoiseException('Handshake reply too short.');
    }
    final re = message.sublist(0, _dhLen);
    await _state.mixHash(re);
    await _state.mixKey(await _dh(_e, re));
    await _state.mixKey(await _dh(_s, re));
    final payload = await _state.decryptAndHash(message.sublist(_dhLen));
    final (send, receive) = await _state.split();
    return (payload, NoiseSession(send, receive, _state.hash));
  }
}

/// Splits [plaintext] into frames: a flag byte (1 = last piece) and a piece,
/// each one Noise transport message.
Future<List<Uint8List>> sealMessage(
  CipherState cipher,
  List<int> plaintext,
) async {
  final frames = <Uint8List>[];
  var offset = 0;
  do {
    final end = (offset + maxPiece).clamp(0, plaintext.length);
    final last = end >= plaintext.length;
    frames.add(
      Uint8List.fromList(
        await cipher.encrypt(const [], [
          last ? 1 : 0,
          ...plaintext.sublist(offset, end),
        ]),
      ),
    );
    offset = end;
  } while (offset < plaintext.length);
  return frames;
}

/// File bytes outside JSON: a stream the phone named, at an offset.
class DataFrame {
  const DataFrame(this.stream, this.offset, this.bytes);
  final int stream;
  final int offset;
  final Uint8List bytes;
}

/// Bytes of file data one frame carries.
const dataPiece = 64000;

/// Flag 2: a data frame, `[2][stream u32][offset u64][bytes]`, one Noise
/// message.
Future<Uint8List> sealData(
  CipherState cipher,
  int stream,
  int offset,
  List<int> bytes,
) async {
  final header = ByteData(13)
    ..setUint8(0, 2)
    ..setUint32(1, stream)
    ..setUint64(5, offset);
  return Uint8List.fromList(
    await cipher.encrypt(const [], [...header.buffer.asUint8List(), ...bytes]),
  );
}

/// Reassembles pieces; returns a whole message once its last piece arrives,
/// or a [DataFrame] as it comes (between messages, never inside one).
class MessageReader {
  final _pieces = BytesBuilder(copy: false);
  final int limit;
  MessageReader([this.limit = 32 * 1024 * 1024]);

  Future<Object?> read(CipherState cipher, List<int> frame) async {
    final plaintext = await cipher.decrypt(const [], frame);
    if (plaintext.length >= 13 && plaintext[0] == 2) {
      final bytes = Uint8List.fromList(plaintext);
      final view = ByteData.sublistView(bytes);
      return DataFrame(
        view.getUint32(1),
        view.getUint64(5),
        Uint8List.sublistView(bytes, 13),
      );
    }
    if (plaintext.isEmpty || plaintext[0] > 1) {
      throw const NoiseException('Bad frame.');
    }
    _pieces.add(plaintext.sublist(1));
    if (_pieces.length > limit) {
      throw const NoiseException('Message too large.');
    }
    if (plaintext[0] != 1) return null;
    return _pieces.takeBytes();
  }
}

/// X25519 private scalar of an Ed25519 seed (RFC 8032 §5.1.5).
Future<List<int>> x25519FromEd25519Seed(List<int> seed) async =>
    (await Sha512().hash(seed)).bytes.sublist(0, 32);

/// Birational map from an Ed25519 public key to its X25519 u-coordinate.
Uint8List x25519PublicFromEd25519(List<int> publicKey) {
  if (publicKey.length != 32) {
    throw const NoiseException('Ed25519 public keys are 32 bytes.');
  }
  final bytes = Uint8List.fromList(publicKey);
  bytes[31] &= 0x7f;
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    y = (y << 8) | BigInt.from(bytes[i]);
  }
  if (y >= _p) throw const NoiseException('Invalid Ed25519 public key.');
  final denominator = (BigInt.one - y) % _p;
  if (denominator == BigInt.zero) {
    throw const NoiseException('Invalid Ed25519 public key.');
  }
  var u = ((BigInt.one + y) * denominator.modInverse(_p)) % _p;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = (u & BigInt.from(0xff)).toInt();
    u >>= 8;
  }
  return out;
}
