import 'dart:convert';

/// `baya://pair?t=<token>&epk=<host key>&n=<name>&rm=<room>&r=<relay>`
///
/// - `t`: single-use token (16–64 bytes, base64url)
/// - `epk`: host Ed25519 public key (32 bytes, base64url), its relay peer id
/// - `n`: session name
/// - `rm`: room of the session that issued the token
/// - `r`: relay URL the host listens on; scanning adopts it
class QrPairPayload {
  final String token;
  final String epk;
  final String sessionName;
  final String roomId;
  final String endpoint;

  const QrPairPayload({
    required this.token,
    required this.epk,
    required this.sessionName,
    required this.roomId,
    required this.endpoint,
  });

  static QrPairPayload? tryParse(String raw) {
    try {
      final uri = Uri.parse(raw.trim());
      if (uri.scheme != 'baya' || uri.host != 'pair') return null;
      final q = uri.queryParameters;
      final t = q['t'], epk = q['epk'], n = q['n'], rm = q['rm'], r = q['r'];
      if (t == null || epk == null || n == null) return null;
      if (rm == null || rm.isEmpty || r == null || r.isEmpty) return null;
      final tokenBytes = base64Url.decode(_pad(t)).length;
      if (tokenBytes < 16 || tokenBytes > 64) return null;
      if (base64Url.decode(_pad(epk)).length != 32) return null;
      return QrPairPayload(
        token: t,
        epk: epk,
        sessionName: n,
        roomId: rm,
        endpoint: r,
      );
    } catch (_) {
      return null;
    }
  }

  List<int> get epkBytes => base64Url.decode(_pad(epk));

  static String _pad(String s) => s + '=' * ((4 - s.length % 4) % 4);
}
