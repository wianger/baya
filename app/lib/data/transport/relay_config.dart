// Relay endpoint resolution.
//
// The app talks to one relay at a time: `prefs.relayUrl` when set (the
// pairing QR sets it, Settings can change it), otherwise [kDefaultRelayUrl].
// URLs are stored as http(s)://; the WebSocket transport converts them with
// [toWsRelayUrl] and the mesh client uses them as-is.

import 'package:app/data/preferences/preferences.dart';

/// The project relay, used until a pairing QR or Settings names another.
const String kDefaultRelayUrl = 'https://wiang-1.tail171f4a.ts.net';

/// User-facing message returned when [isValidRelayUrl] rejects a value.
/// Surfaced verbatim by Settings and Onboarding — keep stable for
/// localization later. Empty input gets a more generic message; the
/// ws/wss case is called out explicitly so the user understands the
/// app does the conversion internally.
const String kRelayUrlInvalidScheme =
    'Use http:// or https:// (not ws:// or wss:// — the app converts '
    'to WebSocket automatically).';

const String kRelayUrlInvalidGeneric =
    'Enter a valid URL starting with https:// (or http:// for local '
    'relays).';

/// Returns the effective relay URL the app should connect to.
/// Falls back to [kDefaultRelayUrl] when no user override is set.
/// Always returns an `http(s)://` URL — caller is responsible for
/// applying [toWsRelayUrl] when opening a WebSocket.
String resolveRelayUrl(Preferences prefs) => prefs.relayUrl ?? kDefaultRelayUrl;

/// Translates the canonical HTTP-form relay URL into the WebSocket
/// form expected by the underlying transport. `https://` → `wss://`,
/// `http://` → `ws://`.
String toWsRelayUrl(String url) {
  if (url.startsWith('https://')) return 'wss://${url.substring(8)}';
  if (url.startsWith('http://')) return 'ws://${url.substring(7)}';
  return url;
}

/// Validates a candidate relay URL the user typed into Settings or
/// the onboarding form.
///
/// Rules:
/// - Non-empty.
/// - Scheme must be `http://` or `https://`. Returns `false` (with the
///   ws/wss-specific reason via [relayUrlValidationMessage]) for
///   `ws://` / `wss://` — the app converts internally.
/// - Must be parseable by `Uri.parse` AND yield a non-empty `host`.
bool isValidRelayUrl(String url) {
  if (url.isEmpty) return false;
  if (url.startsWith('ws://') || url.startsWith('wss://')) {
    return false;
  }
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return false;
  }
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return false;
  }
  if (uri.host.isEmpty) return false;
  return true;
}

/// Returns the user-facing rejection message for [url]. Returns `null`
/// when the URL is valid. Distinguishes the ws/wss case (specific
/// hint about internal conversion) from generic invalid scheme /
/// malformed input.
String? relayUrlValidationMessage(String url) {
  if (url.isEmpty) return kRelayUrlInvalidGeneric;
  if (url.startsWith('ws://') || url.startsWith('wss://')) {
    return kRelayUrlInvalidScheme;
  }
  if (isValidRelayUrl(url)) return null;
  return kRelayUrlInvalidGeneric;
}
