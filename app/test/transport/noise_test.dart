import 'dart:convert';
import 'dart:io';

import 'package:app/data/transport/host_socket.dart';
import 'package:app/data/transport/noise.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _hex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Map<String, dynamic> _contract(String name) =>
    jsonDecode(File('../.orchestration/contracts/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('matches the cacophony IK vector: handshake and transport', () async {
    final v = _contract('noise_ik_vector.json');
    final initiator = await NoiseInitiator.create(
      prologue: _hex(v['init_prologue'] as String),
      staticKey: await x25519KeyPair(_hex(v['init_static'] as String)),
      remoteStatic: _hex(v['init_remote_static'] as String),
      ephemeral: await x25519KeyPair(_hex(v['init_ephemeral'] as String)),
    );
    final messages = (v['messages'] as List).cast<Map<String, dynamic>>();
    final first = await initiator.writeMessage(
      _hex(messages[0]['payload'] as String),
    );
    expect(_toHex(first), messages[0]['ciphertext']);
    final (payload, session) = await initiator.readMessage(
      _hex(messages[1]['ciphertext'] as String),
    );
    expect(_toHex(payload), messages[1]['payload']);
    expect(_toHex(session.handshakeHash), v['handshake_hash']);
    // The initiator sends the even transport messages, receives the odd ones.
    for (var i = 2; i < messages.length; i++) {
      final m = messages[i];
      if (i.isEven) {
        expect(
          _toHex(
            await session.send.encrypt(const [], _hex(m['payload'] as String)),
          ),
          m['ciphertext'],
        );
      } else {
        expect(
          _toHex(
            await session.receive.decrypt(
              const [],
              _hex(m['ciphertext'] as String),
            ),
          ),
          m['payload'],
        );
      }
    }
  });

  test('reproduces the Baya handshake the host expects', () async {
    final v = _contract('noise_baya_vector.json');
    final seed = base64.decode(v['phone_ed25519_seed'] as String);
    expect(
      base64.encode(
        x25519PublicFromEd25519(
          base64.decode(v['host_ed25519_public'] as String),
        ),
      ),
      v['host_x25519_public'],
    );
    final initiator = await NoiseInitiator.create(
      prologue: noisePrologue,
      staticKey: await x25519KeyPair(await x25519FromEd25519Seed(seed)),
      remoteStatic: x25519PublicFromEd25519(
        base64.decode(v['host_ed25519_public'] as String),
      ),
      ephemeral: await x25519KeyPair(
        base64.decode(v['phone_ephemeral'] as String),
      ),
    );
    final hello = await initiator.writeMessage(
      utf8.encode(v['hello'] as String),
    );
    expect(base64.encode(hello), v['message1']);
    final (_, session) = await initiator.readMessage(
      base64.decode(v['message2'] as String),
    );
    expect(base64.encode(session.handshakeHash), v['handshake_hash']);
    final frames = await sealMessage(
      session.send,
      utf8.encode(v['request'] as String),
    );
    expect(base64.encode(frames.single), v['request_frame']);
    final reply = await MessageReader().read(
      session.receive,
      base64.decode(v['response_frame'] as String),
    );
    expect(utf8.decode(reply!), v['response']);
  });

  test('large messages are split into pieces and reassembled', () async {
    final a = CipherState()..initialize(List.filled(32, 1));
    final b = CipherState()..initialize(List.filled(32, 1));
    final big = List.filled(maxPiece * 2 + 5, 9);
    final frames = await sealMessage(a, big);
    expect(frames, hasLength(3));
    final reader = MessageReader();
    expect(await reader.read(b, frames[0]), isNull);
    expect(await reader.read(b, frames[1]), isNull);
    expect(await reader.read(b, frames[2]), big);
  });

  test('a tampered or replayed frame is rejected', () async {
    final a = CipherState()..initialize(List.filled(32, 2));
    final b = CipherState()..initialize(List.filled(32, 2));
    final frame = (await sealMessage(a, [1, 2, 3])).single;
    final tampered = [...frame]..[3] ^= 1;
    await expectLater(
      MessageReader().read(b, tampered),
      throwsA(isA<NoiseException>()),
    );
    final c = CipherState()..initialize(List.filled(32, 2));
    await MessageReader().read(c, frame);
    await expectLater(
      MessageReader().read(c, frame),
      throwsA(isA<NoiseException>()),
    );
  });
}
