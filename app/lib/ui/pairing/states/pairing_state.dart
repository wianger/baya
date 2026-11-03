import 'package:app/pairing/storage.dart';

sealed class PairingState {
  const PairingState();
}

/// Initial state — UI not yet showing the scanner.
class PairingIdle extends PairingState {
  const PairingIdle();
}

/// Camera viewfinder visible; waiting for a valid QR scan.
class PairingScanning extends PairingState {
  const PairingScanning();
}

/// QR scanned; connecting and calling `_baya/pair`.
class PairingConnecting extends PairingState {
  final String sessionName;
  const PairingConnecting({required this.sessionName});
}

/// The computer accepted the code. UI navigates straight to chat
/// after the post-pair nickname modal is dismissed.
///
/// [hostnameHint] is the computer's hostname `_baya/pair` returned; the
/// post-pair nickname modal pre-fills its input with it.
class PairingPaired extends PairingState {
  final PeerRecord peer;
  final String? hostnameHint;
  const PairingPaired({required this.peer, this.hostnameHint});

  @override
  bool operator ==(Object other) =>
      other is PairingPaired &&
      other.peer.remoteEpk == peer.remoteEpk &&
      other.hostnameHint == hostnameHint;

  @override
  int get hashCode => Object.hash(peer.remoteEpk, hostnameHint);
}

/// QR parse, connection, or pairing failed.
class PairingError extends PairingState {
  final String message;
  final bool canRetry;
  const PairingError({required this.message, this.canRetry = true});
}
