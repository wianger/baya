import 'dart:convert';

import 'package:app/pairing/tailnet_pairing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('asks the named computer on the tailnet for a pairing code', () async {
    late Uri asked;
    final code = await fetchTailnetPairingCode(
      ' Wiang-1 ',
      client: MockClient((request) async {
        asked = request.url;
        return http.Response(jsonEncode({'uri': 'baya://pair?t=x'}), 200);
      }),
    );
    expect(code, 'baya://pair?t=x');
    expect(asked.toString(), 'http://wiang-1:7480/pair');
  });

  test('prefers HTTPS through tailscale serve, then the direct port', () async {
    final asked = <String>[];
    final code = await fetchTailnetPairingCode(
      'wiang-1',
      tailnetSuffix: tailnetSuffixOf('https://relay.tail1234.ts.net'),
      client: MockClient((request) async {
        asked.add(request.url.toString());
        if (request.url.scheme == 'https') return http.Response('', 404);
        return http.Response(jsonEncode({'uri': 'baya://pair?t=y'}), 200);
      }),
    );
    expect(code, 'baya://pair?t=y');
    expect(asked, [
      'https://wiang-1.tail1234.ts.net/baya-pair/pair',
      'http://wiang-1:7480/pair',
    ]);
    expect(tailnetSuffixOf('https://example.com'), isNull);
  });

  test('maps refusals and network errors to precise reasons', () async {
    Future<TailnetPairingFailure?> reason(http.Client client) async {
      try {
        await fetchTailnetPairingCode('box', client: client);
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
      await reason(MockClient((_) async => http.Response('{}', 503))),
      TailnetPairingFailure.notReady,
    );
    expect(
      await reason(MockClient((_) async => throw http.ClientException('down'))),
      TailnetPairingFailure.unreachable,
    );
  });
}
