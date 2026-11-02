import 'dart:convert';

import 'package:http/http.dart' as http;

/// Why a Tailscale pairing request failed, for a precise message.
enum TailnetPairingFailure { notYourAccount, unreachable, notReady }

class TailnetPairingException implements Exception {
  final TailnetPairingFailure reason;
  const TailnetPairingException(this.reason);
}

/// Port the host's Tailscale pairing endpoint listens on.
const kTailnetPairingPort = 7480;

/// Asks the computer called [name] on this tailnet for a pairing code.
///
/// The host answers only to devices signed in to the same Tailscale account
/// (it checks with `tailscale whois`), and the request travels inside the
/// tailnet's WireGuard tunnel, so the code is as trustworthy as a scanned QR.
Future<String> fetchTailnetPairingCode(
  String name, {
  http.Client? client,
}) async {
  final host = name.trim().toLowerCase();
  final uri = Uri(
    scheme: 'http',
    host: host,
    port: kTailnetPairingPort,
    path: '/pair',
  );
  final http.Response response;
  try {
    response = await (client ?? http.Client())
        .get(uri)
        .timeout(const Duration(seconds: 8));
  } catch (_) {
    throw const TailnetPairingException(TailnetPairingFailure.unreachable);
  }
  switch (response.statusCode) {
    case 200:
      final body = jsonDecode(response.body);
      if (body is Map && body['uri'] is String) return body['uri'] as String;
      throw const TailnetPairingException(TailnetPairingFailure.notReady);
    case 403:
      throw const TailnetPairingException(TailnetPairingFailure.notYourAccount);
    default:
      throw const TailnetPairingException(TailnetPairingFailure.notReady);
  }
}
