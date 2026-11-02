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
/// Tries, in order:
/// 1. `https://<full name>/baya-pair/pair` — through the computer's
///    `tailscale serve`, which works even when inbound connections are
///    firewalled (WSL). A short name is completed with [tailnetSuffix]
///    (e.g. `tail1234.ts.net`, taken from the relay address).
/// 2. `http://<name>:7480/pair` — the host's direct tailnet listener.
///
/// The host answers only to devices of the same Tailscale account, and both
/// paths stay inside the tailnet, so the code is as trustworthy as a scan.
Future<String> fetchTailnetPairingCode(
  String name, {
  String? tailnetSuffix,
  http.Client? client,
}) async {
  final host = name.trim().toLowerCase();
  final fullName = host.contains('.')
      ? host
      : (tailnetSuffix == null ? null : '$host.$tailnetSuffix');
  final candidates = [
    if (fullName != null)
      Uri(scheme: 'https', host: fullName, path: '/baya-pair/pair'),
    Uri(scheme: 'http', host: host, port: kTailnetPairingPort, path: '/pair'),
  ];
  final http_ = client ?? http.Client();
  TailnetPairingException? last;
  for (final uri in candidates) {
    final http.Response response;
    try {
      response = await http_.get(uri).timeout(const Duration(seconds: 8));
    } catch (_) {
      last = const TailnetPairingException(TailnetPairingFailure.unreachable);
      continue;
    }
    switch (response.statusCode) {
      case 200:
        final body = jsonDecode(response.body);
        if (body is Map && body['uri'] is String) return body['uri'] as String;
        throw const TailnetPairingException(TailnetPairingFailure.notReady);
      case 403:
        throw const TailnetPairingException(
          TailnetPairingFailure.notYourAccount,
        );
      case 404:
        // This path is not set up on that computer; try the next one.
        last = const TailnetPairingException(TailnetPairingFailure.unreachable);
      default:
        last = const TailnetPairingException(TailnetPairingFailure.notReady);
    }
  }
  throw last ??
      const TailnetPairingException(TailnetPairingFailure.unreachable);
}

/// The tailnet domain of a `*.ts.net` relay address, e.g. `tail1234.ts.net`.
String? tailnetSuffixOf(String relayUrl) {
  final host = Uri.tryParse(relayUrl)?.host ?? '';
  final parts = host.split('.');
  if (parts.length < 3 || !host.endsWith('.ts.net')) return null;
  return parts.sublist(parts.length - 3).join('.');
}
