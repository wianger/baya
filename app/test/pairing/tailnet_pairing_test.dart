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
      tailnetSuffix: tailnetSuffixOf('https://relay.tail1234.ts.net'),
      client: MockClient((request) async {
        final url = request.url.toString();
        return switch (url) {
          'https://wiang-1.tail1234.ts.net/baya-pair/wsl/info' => _info(
            'wsl',
            'k1',
          ),
          // Legacy serve mapping reaches the same WSL host.
          'https://wiang-1.tail1234.ts.net/baya-pair/info' => _info(
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

  test('falls back to the direct tailnet port', () async {
    final hosts = await discoverTailnetHosts(
      'box',
      client: MockClient((request) async {
        if (request.url.toString() == 'http://box:7480/info') {
          return _info('linux', 'k');
        }
        throw http.ClientException('unreachable');
      }),
    );
    expect(hosts.single.pairUri.toString(), 'http://box:7480/pair');
  });

  test('explains refusals and silence', () async {
    Future<TailnetPairingFailure?> reason(http.Client client) async {
      try {
        await discoverTailnetHosts('box', client: client);
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
          jsonEncode({'uri': 'baya://pair?t=z&r=https://relay'}),
          200,
        ),
      ),
    );
    // The code names the host itself: it is reached without the relay.
    expect(Uri.parse(code).queryParameters, {
      't': 'z',
      'r': 'https://box.t.ts.net/baya-pair/windows/direct',
    });
    expect(
      TailnetHost(
        label: 'linux',
        name: 'box',
        key: 'k',
        pairUri: Uri.parse('http://box:7480/pair'),
      ).endpoint,
      'http://box:7480/direct',
    );
    expect(tailnetSuffixOf('https://example.com'), isNull);
  });
}
