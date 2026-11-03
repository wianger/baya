import 'dart:convert';

/// `baya://pair?t=<token>&epk=<host key>&n=<name>&e=<endpoint>`
///
/// - `t`: single-use token (16–64 bytes, base64url)
/// - `epk`: host Ed25519 public key (32 bytes, base64url)
/// - `n`: the computer's name
/// - `e`: where the phone reaches the host (its Tailscale `…/direct` address)
class QrPairPayload {
  final String token;
  final String epk;

  /// The computer's name, e.g. `studio (WSL)`.
  final String name;
  final String endpoint;

  const QrPairPayload({
    required this.token,
    required this.epk,
    required this.name,
    required this.endpoint,
  });

  static QrPairPayload? tryParse(String raw) {
    try {
      final uri = Uri.parse(raw.trim());
      if (uri.scheme != 'baya' || uri.host != 'pair') return null;
      final q = uri.queryParameters;
      final t = q['t'], epk = q['epk'], n = q['n'], e = q['e'];
      if (t == null || epk == null || n == null) return null;
      if (e == null || e.isEmpty) return null;
      final tokenBytes = base64Url.decode(_pad(t)).length;
      if (tokenBytes < 16 || tokenBytes > 64) return null;
      if (base64Url.decode(_pad(epk)).length != 32) return null;
      return QrPairPayload(token: t, epk: epk, name: n, endpoint: e);
    } catch (_) {
      return null;
    }
  }

  List<int> get epkBytes => base64Url.decode(_pad(epk));

  static String _pad(String s) => s + '=' * ((4 - s.length % 4) % 4);
}
