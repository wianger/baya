import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Why a Tailscale pairing request failed, for a precise message.
enum TailnetPairingFailure {
  notYourAccount,
  unreachable,
  notReady,

  /// A short name was typed but the tailnet domain could not be found.
  unknownTailnet,
}

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

/// Finds the Baya hosts on the computer called [name].
///
/// A short name is completed with [tailnetSuffix] (the tailnet of an earlier
/// pairing) or else [findTailnetDomain], because the HTTPS certificate is
/// issued for the full `*.ts.net` name.
///
/// Each host is published by the computer's `tailscale serve` at
/// `https://<full name>/baya-pair/<label>` and answers `…/info` only to
/// devices of the same Tailscale account, so what comes back is as
/// trustworthy as a scanned code. All labels are probed in parallel.
Future<List<TailnetHost>> discoverTailnetHosts(
  String name, {
  String? tailnetSuffix,
  http.Client? client,
  Future<String?> Function() findTailnetDomain = tailnetDomainOfThisPhone,
}) async {
  final host = name.trim().toLowerCase();
  final String fullName;
  if (host.contains('.')) {
    fullName = host;
  } else {
    final domain = tailnetSuffix ?? await findTailnetDomain();
    if (domain == null) {
      throw const TailnetPairingException(TailnetPairingFailure.unknownTailnet);
    }
    fullName = '$host.$domain';
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

/// The tailnet domain of a `*.ts.net` address, e.g. `tail1234.ts.net`.
String? tailnetSuffixOf(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  final parts = host.split('.');
  if (parts.length < 3 || !host.endsWith('.ts.net')) return null;
  return parts.sublist(parts.length - 3).join('.');
}

/// The tailnet domain (e.g. `tail1234.ts.net`) of the Tailscale account this
/// phone is signed in to: the MagicDNS name of the phone's own tailnet
/// address, asked of Tailscale's resolver directly. Null when Tailscale is
/// off.
Future<String?> tailnetDomainOfThisPhone() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    for (final address in interfaces.expand((i) => i.addresses)) {
      if (!isTailnetAddress(address.address)) continue;
      final name = await _askMagicDns(ptrQuery(address.address));
      final domain = name == null ? null : tailnetSuffixOf('https://$name');
      if (domain != null) return domain;
    }
  } catch (_) {
    // No usable answer: the caller asks for the full name.
  }
  return null;
}

/// Tailscale addresses are in 100.64.0.0/10.
bool isTailnetAddress(String ipv4) {
  final parts = ipv4.split('.').map(int.tryParse).toList();
  return parts.length == 4 &&
      parts[0] == 100 &&
      (parts[1] ?? 0) >= 64 &&
      (parts[1] ?? 0) < 128;
}

/// A DNS query (id 0xBA1A, recursion desired) for the PTR of [ipv4].
List<int> ptrQuery(String ipv4) {
  final name = '${ipv4.split('.').reversed.join('.')}.in-addr.arpa';
  return [
    0xBA, 0x1A, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, // header, 1 question
    for (final label in name.split('.')) ...[label.length, ...label.codeUnits],
    0, 0, 12, 0, 1, // root, type PTR, class IN
  ];
}

/// The first PTR target in a DNS [response], without the trailing dot.
String? ptrAnswer(List<int> response) {
  if (response.length < 12 || response[0] != 0xBA || response[1] != 0x1A) {
    return null;
  }
  final answers = response[6] << 8 | response[7];
  var offset = 12;
  offset = _skipName(response, offset) + 4; // question name, type, class
  for (var i = 0; i < answers; i++) {
    offset = _skipName(response, offset);
    final type = response[offset] << 8 | response[offset + 1];
    final length = response[offset + 8] << 8 | response[offset + 9];
    offset += 10;
    if (type == 12) return _readName(response, offset);
    offset += length;
  }
  return null;
}

int _skipName(List<int> bytes, int offset) {
  while (bytes[offset] != 0) {
    if (bytes[offset] & 0xC0 == 0xC0) return offset + 2;
    offset += bytes[offset] + 1;
  }
  return offset + 1;
}

String _readName(List<int> bytes, int offset) {
  final labels = <String>[];
  for (var guard = 0; guard < 64 && bytes[offset] != 0; guard++) {
    if (bytes[offset] & 0xC0 == 0xC0) {
      offset = (bytes[offset] & 0x3F) << 8 | bytes[offset + 1];
      continue;
    }
    final length = bytes[offset];
    labels.add(String.fromCharCodes(bytes, offset + 1, offset + 1 + length));
    offset += length + 1;
  }
  return labels.join('.');
}

/// Sends [query] to Tailscale's resolver (100.100.100.100) over UDP.
Future<String?> _askMagicDns(List<int> query) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    final answer = socket
        .where((event) => event == RawSocketEvent.read)
        .map((_) => socket.receive())
        .where((datagram) => datagram != null)
        .map((datagram) => ptrAnswer(datagram!.data))
        .first;
    socket.send(query, InternetAddress('100.100.100.100'), 53);
    return await answer.timeout(const Duration(seconds: 3));
  } finally {
    socket.close();
  }
}
