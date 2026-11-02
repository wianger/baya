import 'dart:convert';

import 'package:app/pairing/tailnet_pairing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _info(String label, String key) => http.Response(
  jsonEncode({'label': label, 'name': 'BOX ($label)', 'key': key}),
  200,
);

void main() {
  test('finds every Baya on the computer, once each', () async {
    final hosts = await discoverTailnetHosts(
      'Wiang-1',
      tailnetSuffix: tailnetSuffixOf(
        'https://pc.tail1234.ts.net/baya-pair/wsl/direct',
      ),
      client: MockClient((request) async {
        final url = request.url.toString();
        return switch (url) {
          'https://wiang-1.tail1234.ts.net/baya-pair/wsl/info' => _info(
            'wsl',
            'k1',
          ),
          'https://wiang-1.tail1234.ts.net/baya-pair/windows/info' => _info(
            'windows',
            'k2',
          ),
          _ => http.Response('', 404),
        };
      }),
    );
    expect(hosts.map((h) => h.label), ['wsl', 'windows']);
    expect(
      hosts.last.pairUri.toString(),
      'https://wiang-1.tail1234.ts.net/baya-pair/windows/pair',
    );
  });

  test(
    'a short name with no known tailnet uses this phone\'s tailnet',
    () async {
      final hosts = await discoverTailnetHosts(
        'Wiang-1',
        findTailnetDomain: () async => 'tail9.ts.net',
        client: MockClient(
          (request) async =>
              request.url.toString() ==
                  'https://wiang-1.tail9.ts.net/baya-pair/wsl/info'
              ? _info('wsl', 'k')
              : http.Response('', 404),
        ),
      );
      expect(hosts.single.label, 'wsl');
    },
  );

  test('asks for the full name when the tailnet is unknown', () async {
    await expectLater(
      discoverTailnetHosts('box', findTailnetDomain: () async => null),
      throwsA(
        isA<TailnetPairingException>().having(
          (e) => e.reason,
          'reason',
          TailnetPairingFailure.unknownTailnet,
        ),
      ),
    );
  });

  test('reads this phone\'s name from a MagicDNS PTR answer', () {
    final query = ptrQuery('100.65.103.80');
    // Answer: the question echoed, then one PTR whose owner is a pointer to
    // the question name (0xC00C).
    final target = 'pixel.tail9.ts.net'
        .split('.')
        .expand((l) => [l.length, ...l.codeUnits])
        .toList();
    final response = [
      0xBA,
      0x1A,
      0x81,
      0x80,
      0,
      1,
      0,
      1,
      0,
      0,
      0,
      0,
      ...query.sublist(12),
      0xC0,
      0x0C,
      0,
      12,
      0,
      1,
      0,
      0,
      0,
      60,
      0,
      target.length + 1,
      ...target,
      0,
    ];
    expect(ptrAnswer(response), 'pixel.tail9.ts.net');
    expect(ptrAnswer([0, 0, ...response.sublist(2)]), isNull);
    expect(isTailnetAddress('100.65.103.80'), isTrue);
    expect(isTailnetAddress('100.128.0.1'), isFalse);
    expect(isTailnetAddress('192.168.1.2'), isFalse);
  });

  test('explains refusals and silence', () async {
    Future<TailnetPairingFailure?> reason(http.Client client) async {
      try {
        await discoverTailnetHosts(
          'box',
          client: client,
          findTailnetDomain: () async => 't.ts.net',
        );
        return null;
      } on TailnetPairingException catch (e) {
        return e.reason;
      }
    }

    expect(
      await reason(MockClient((_) async => http.Response('{}', 403))),
      TailnetPairingFailure.notYourAccount,
    );
    expect(
      await reason(MockClient((_) async => throw http.ClientException('x'))),
      TailnetPairingFailure.unreachable,
    );
  });

  test('fetches the code from the chosen host', () async {
    final host = TailnetHost(
      label: 'windows',
      name: 'BOX (Windows)',
      key: 'k',
      pairUri: Uri.parse('https://box.t.ts.net/baya-pair/windows/pair'),
    );
    final code = await fetchTailnetPairingCode(
      host,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'uri': 'baya://pair?t=z&e=https://pc/direct'}),
          200,
        ),
      ),
    );
    expect(code, 'baya://pair?t=z&e=https://pc/direct');
    expect(tailnetSuffixOf('https://example.com'), isNull);
  });
}
