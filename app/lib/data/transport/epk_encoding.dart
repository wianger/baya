// Single point of truth for the epk wire-format coercion.
//
//   - QR payload + PairingStorage use base64url (RFC 4648 §5; `-_` chars).
//   - The wire (hello / `peer` envelope field) uses base64 standard
//     (RFC 4648 §4; `+/` chars, `=` padding).
//
// Every transport-bound epk goes through [toStandardB64]; every inbound
// epk goes through [toAppEpk] so it matches the key
// `PairingStorage` already uses.

import 'dart:convert';

/// Convert an epk (possibly base64url from QR/storage) to base64 standard
/// for wire frames. Idempotent — already-standard epks
/// pass through unchanged. Unparseable input returned as-is so we never
/// silently drop a bad-looking peer id.
String toStandardB64(String b64) {
  if (b64.isEmpty) return b64;
  try {
    final pad = (4 - b64.length % 4) % 4;
    final bytes = base64Url.decode(b64 + '=' * pad);
    return base64.encode(bytes);
  } catch (_) {
    return b64;
  }
}

/// Convert an epk from the wire (standard base64) back to the
/// format the app's stores use internally. Today that's base64url so the
/// key matches `PairingStorage`/`PeerRecord.remoteEpk`. Idempotent.
String toAppEpk(String b64) {
  if (b64.isEmpty) return b64;
  try {
    final pad = (4 - b64.length % 4) % 4;
    final bytes = base64.decode(b64 + '=' * pad);
    final out = base64Url.encode(bytes).replaceAll('=', '');
    // Bare bytes don't always round-trip with padding; strip = to match
    // what QR payloads carry.
    return out;
  } on FormatException {
    // Already url-safe? Try the other direction once for symmetry.
    try {
      final pad = (4 - b64.length % 4) % 4;
      base64Url.decode(b64 + '=' * pad);
      return b64;
    } catch (_) {
      return b64;
    }
  }
}
