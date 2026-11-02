// PairRequest flow.
//
// Sequence (over a connected PeerTransport):
//   1. App sends inner JSON {type:"pair_request", id, token, device_name}
//   2. Pi validates token, persists peer, replies pair_ok | pair_error
//   3. App persists PeerRecord on success
//
// No cipher, no safety number — the outer envelope's `ct` is base64 of
// the JSON in plaintext (transparent to PeerTransport implementations).

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/protocol/protocol.dart' show PairOk;
import 'package:app/protocol/uuid7.dart';

import 'qr_scanner.dart';
import 'storage.dart';

// ---------------------------------------------------------------------------
// PeerTransport — minimal byte-level interface (was NoiseTransport pre-rollback)
// ---------------------------------------------------------------------------

abstract class PeerTransport {
  Future<void> send(Uint8List data);
  Future<Uint8List> receive();
  Future<void> close();
}

// ---------------------------------------------------------------------------
// PairingError
// ---------------------------------------------------------------------------

class PairingError implements Exception {
  final String code;
  final String message;
  const PairingError({required this.code, required this.message});

  @override
  String toString() => 'PairingError($code): $message';
}

// ---------------------------------------------------------------------------
// PairingResult — output of [performPairing]
// ---------------------------------------------------------------------------

/// Wraps the persisted [PeerRecord] plus side hints the post-pair UI
/// (nickname modal) needs but that don't belong on the PeerRecord
/// itself. [hostnameHint] lets the modal pre-fill the computer's name
/// instead of the generic "Pi"; legacy hosts
/// that don't emit `hostname` leave it null and the modal falls back
/// to `peer.sessionName`.
class PairingResult {
  final PeerRecord peer;
  final String? hostnameHint;
  const PairingResult({required this.peer, this.hostnameHint});
}

// ---------------------------------------------------------------------------
// performPairing
// ---------------------------------------------------------------------------

Future<PairingResult> performPairing({
  required QrPairPayload qr,
  required PeerTransport transport,
  required PairingStorage storage,
  required String deviceName,
}) async {
  // Address the session room that issued the token from the first frame.
  try {
    (transport as dynamic).setActiveRoom(qr.roomId);
  } catch (_) {
    // In-memory test transports do not route by room.
  }

  final id = uuid7();
  final req = {
    'type': 'pair_request',
    'id': id,
    'token': qr.token,
    'device_name': deviceName,
  };
  await transport.send(Uint8List.fromList(utf8.encode(jsonEncode(req))));

  final raw = await transport.receive();
  final inner = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
  final type = inner['type'] as String?;

  if (type == 'pair_ok' && inner['in_reply_to'] == id) {
    final pairOk = PairOk.fromJson(inner);
    final peer = PeerRecord(
      remoteEpk: qr.epk,
      sessionName: pairOk.sessionName,
      endpoint: qr.endpoint,
      pairedAt: DateTime.now().toUtc().toIso8601String(),
      roomId: pairOk.roomId,
      harness: pairOk.harness,
    );
    await storage.savePeer(peer);
    return PairingResult(peer: peer, hostnameHint: pairOk.hostname);
  }

  if (type == 'pair_error') {
    throw PairingError(
      code: inner['code'] as String,
      message: inner['message'] as String? ?? '',
    );
  }

  throw PairingError(
    code: 'unexpected_response',
    message: 'Unknown response type: $type',
  );
}
