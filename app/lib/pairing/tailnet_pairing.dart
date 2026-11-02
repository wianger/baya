import 'dart:convert';

import 'package:http/http.dart' as http;

/// Why a Tailscale pairing request failed, for a precise message.
enum TailnetPairingFailure { notYourAccount, unreachable, notReady }

class TailnetPairingException implements Exception {
  final TailnetPairingFailure reason;
  const TailnetPairingException(this.reason);
}

/// One Baya host on a computer. Windows and WSL can each run one under the
/// same Tailscale name.
class TailnetHost {
  final String label;
  final String name;
  final String key;
  final Uri pairUri;
  const TailnetHost({
    required this.label,
    required this.name,
    required this.key,
    required this.pairUri,
  });
}

const _labels = ['wsl', 'windows', 'linux', 'macos'];
const _timeout = Duration(seconds: 8);

/// Finds the Baya hosts on the computer called [name] (a short name is
/// completed with [tailnetSuffix]).
///
/// Each host is published by the computer's `tailscale serve` at
/// `https://<full name>/baya-pair/<label>` and answers `…/info` only to
/// devices of the same Tailscale account, so what comes back is as
/// trustworthy as a scanned code. All labels are probed in parallel.
Future<List<TailnetHost>> discoverTailnetHosts(
  String name, {
  String? tailnetSuffix,
  http.Client? client,
}) async {
  final host = name.trim().toLowerCase();
  final fullName = host.contains('.')
      ? host
      : (tailnetSuffix == null ? null : '$host.$tailnetSuffix');
  if (fullName == null) {
    throw const TailnetPairingException(TailnetPairingFailure.unreachable);
  }
  final probes = [
    for (final label in _labels)
      (
        info: Uri.https(fullName, '/baya-pair/$label/info'),
        pair: Uri.https(fullName, '/baya-pair/$label/pair'),
      ),
  ];
  final http_ = client ?? http.Client();
  var refused = false;
  final results = await Future.wait(
    probes.map((probe) async {
      try {
        final response = await http_.get(probe.info).timeout(_timeout);
        if (response.statusCode == 403) refused = true;
        if (response.statusCode != 200) return null;
        final body = jsonDecode(response.body);
        if (body is! Map ||
            body['label'] is! String ||
            body['name'] is! String ||
            body['key'] is! String) {
          return null;
        }
        return TailnetHost(
          label: body['label'] as String,
          name: body['name'] as String,
          key: body['key'] as String,
          pairUri: probe.pair,
        );
      } catch (_) {
        return null;
      }
    }),
  );
  // One entry per host.
  final byKey = <String, TailnetHost>{};
  for (final found in results.whereType<TailnetHost>()) {
    byKey.putIfAbsent(found.key, () => found);
  }
  if (byKey.isEmpty) {
    throw TailnetPairingException(
      refused
          ? TailnetPairingFailure.notYourAccount
          : TailnetPairingFailure.unreachable,
    );
  }
  return byKey.values.toList();
}

/// A fresh pairing code from [host], used exactly like a scanned one. It
/// names the host's own address, so the computer is reached directly.
Future<String> fetchTailnetPairingCode(
  TailnetHost host, {
  http.Client? client,
}) async {
  final http.Response response;
  try {
    response = await (client ?? http.Client())
        .get(host.pairUri)
        .timeout(_timeout);
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

/// The tailnet domain of a `*.ts.net` relay address, e.g. `tail1234.ts.net`.
String? tailnetSuffixOf(String relayUrl) {
  final host = Uri.tryParse(relayUrl)?.host ?? '';
  final parts = host.split('.');
  if (parts.length < 3 || !host.endsWith('.ts.net')) return null;
  return parts.sublist(parts.length - 3).join('.');
}
