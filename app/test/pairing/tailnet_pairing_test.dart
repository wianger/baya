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

  test('a short name with no known tailnet is completed by MagicDNS', () async {
    final hosts = await discoverTailnetHosts(
      'Wiang-1',
      resolveFullName: (short) async =>
          short == 'wiang-1' ? 'wiang-1.tail9.ts.net' : null,
      client: MockClient(
        (request) async =>
            request.url.toString() ==
                'https://wiang-1.tail9.ts.net/baya-pair/wsl/info'
            ? _info('wsl', 'k')
            : http.Response('', 404),
      ),
    );
    expect(hosts.single.label, 'wsl');
  });

  test('explains refusals and silence', () async {
    Future<TailnetPairingFailure?> reason(http.Client client) async {
      try {
        await discoverTailnetHosts(
          'box',
          client: client,
          resolveFullName: (_) async => 'box.t.ts.net',
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
