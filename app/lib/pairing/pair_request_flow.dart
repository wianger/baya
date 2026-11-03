// Pairing: trade a one-time code for a lasting pairing.
//
// The phone opens the computer's socket with its own key (which the computer
// does not know yet), calls `_baya/pair` with the code, and saves the
// computer once it says yes.

import 'dart:async';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transport/host_socket.dart';

import 'qr_scanner.dart';
import 'storage.dart';

class PairingError implements Exception {
  /// `token_expired`, `token_consumed`, `token_unknown` or `unreachable`.
  final String code;
  final String message;
  const PairingError({required this.code, required this.message});

  @override
  String toString() => 'PairingError($code): $message';
}

class PairingResult {
  final PeerRecord peer;

  /// The computer's hostname, to pre-fill the nickname prompt.
  final String? hostnameHint;
  const PairingResult({required this.peer, this.hostnameHint});
}

Future<PairingResult> performPairing({
  required QrPairPayload qr,
  required HostSocket socket,
  required PairingStorage storage,
  required String deviceName,
}) async {
  final peer = JsonRpcPeer(
    write: socket.send,
    onRequest: (method, _, _) async =>
        throw RpcError(RpcError.methodNotFound, method),
    onNotification: (_, _) {},
  );
  final subscription = socket.messages.listen(peer.receive);
  unawaited(
    socket.closed.then(
      (_) => peer.close(const RpcClosed('The computer closed the connection.')),
    ),
  );
  try {
    final result = await peer
        .call('_baya/pair', {'token': qr.token, 'deviceName': deviceName})
        .timeout(const Duration(seconds: 15));
    final record = PeerRecord(
      remoteEpk: qr.epk,
      name: qr.name,
      endpoint: qr.endpoint,
      pairedAt: DateTime.now().toUtc().toIso8601String(),
    );
    await storage.savePeer(record);
    return PairingResult(
      peer: record,
      hostnameHint: result['hostname'] as String?,
    );
  } on RpcError catch (error) {
    throw PairingError(
      code: error.reason ?? 'internal_error',
      message: error.message,
    );
  } finally {
    await subscription.cancel();
    peer.close(const RpcClosed('Pairing finished.'));
  }
}
