import 'package:app/pairing/qr_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const token = 'AAAAAAAAAAAAAAAAAAAAAA';
  const epk = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const relay = 'https%3A%2F%2Frelay.example';

  test('parses a complete baya:// pairing code', () {
    final qr = QrPairPayload.tryParse(
      'baya://pair?t=$token&epk=$epk&n=Review&rm=room1&r=$relay',
    )!;
    expect(qr.token, token);
    expect(qr.epk, epk);
    expect(qr.sessionName, 'Review');
    expect(qr.roomId, 'room1');
    expect(qr.relayUrl, 'https://relay.example');
    expect(qr.epkBytes, hasLength(32));
  });

  test('accepts tokens of 16 to 64 bytes', () {
    const long = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; // 24 bytes
    expect(
      QrPairPayload.tryParse(
        'baya://pair?t=$long&epk=$epk&n=Review&rm=room1&r=$relay',
      ),
      isNotNull,
    );
  });

  test('rejects other schemes and incomplete or malformed codes', () {
    for (final raw in [
      'remotepi://pair?t=$token&epk=$epk&n=Review&rm=room1&r=$relay',
      'baya://pair?t=$token&epk=$epk&n=Review&rm=room1',
      'baya://pair?t=$token&epk=$epk&n=Review&r=$relay',
      'baya://pair?epk=$epk&n=Review&rm=room1&r=$relay',
      'baya://pair?t=AAAA&epk=$epk&n=Review&rm=room1&r=$relay',
      'baya://pair?t=$token&epk=AAAA&n=Review&rm=room1&r=$relay',
      'baya://other?t=$token&epk=$epk&n=Review&rm=room1&r=$relay',
      'not a uri',
    ]) {
      expect(QrPairPayload.tryParse(raw), isNull, reason: raw);
    }
  });
}
