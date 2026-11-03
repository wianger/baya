import 'dart:async';
import 'dart:typed_data';

import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:baya_identity/baya_identity.dart';

/// Outcome of `bridge.boot()`: the owner identity, and whether this run
/// created it (a fresh install goes through onboarding).
final class IdentityReady {
  final OwnerIdentity identity;
  final bool generated;
  const IdentityReady(this.identity, {required this.generated});
}

/// Bridge between the `baya_identity` plugin and the rest of the
/// app. Responsibilities:
///
/// - Boot-time decision: sync available? identity present?
/// - `currentIdentity` getter for callers that need the Owner-sk for
///   the host's challenge-response (production transport factory).
/// - Watch-on-sync hook: when the platform delivers a different
///   Owner-key (restored on a new device, owner re-installed elsewhere),
///   wipe local peer and session-list caches because the previous device's
///   `remote_epk` set is meaningless against a fresh identity.
class OwnerIdentityBridge extends ChangeNotifier {
  final OwnerIdentityStore _store;
  final PairingStorage _pairing;
  final Ed25519 _ed25519 = Ed25519();

  OwnerIdentity? _current;
  StreamSubscription<OwnerIdentity>? _watchSub;
  bool _disposed = false;

  OwnerIdentityBridge(this._store, this._pairing);

  OwnerIdentity? get currentIdentity => _current;

  /// Public key of the currently-loaded Owner identity (or null when
  /// the bridge hasn't booted yet). Surfaces this for the router's
  /// guard logic.
  Uint8List? get currentOwnerPk => _current?.ownerPk;

  /// Load the Owner identity, or create one on first run.
  Future<IdentityReady> boot() async {
    try {
      final loaded = await _store.load();
      if (loaded != null) {
        _current = loaded;
        return IdentityReady(loaded, generated: false);
      }
    } on IdentityStoreError {
      // Unreadable: start over with a fresh identity.
    }
    final generated = await _generateAndSave();
    _current = generated;
    return IdentityReady(generated, generated: true);
  }

  Future<OwnerIdentity> _generateAndSave() async {
    final kp = await _ed25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final priv = await kp.extractPrivateKeyBytes();
    final id = OwnerIdentity(
      ownerPk: Uint8List.fromList(pub.bytes),
      ownerSk: Uint8List.fromList(priv),
    );
    await _store.save(id);
    return id;
  }

  /// Rehydrate a `SimpleKeyPair` from the cached Owner identity. Used
  /// at challenge-response time — callers must have already gone
  /// through [boot] (otherwise [currentIdentity] would still be null
  /// and this throws `StateError`).
  Future<SimpleKeyPair> requireKeyPair() async {
    final id = _current;
    if (id == null) {
      throw StateError(
        'OwnerIdentityBridge.requireKeyPair() called before boot() — '
        'router should have gated this path on IdentityReady.',
      );
    }
    return _ed25519.newKeyPairFromSeed(id.ownerSk);
  }

  /// Subscribe to platform sync events. When the incoming Owner-pk
  /// differs from [_current], the bridge:
  ///   1. wipes [PairingStorage] (peers + session lists) — stale handles.
  ///   2. caches the new identity.
  ///   3. calls [onReset] so the host can force a fresh router boot.
  ///
  /// Same-pk events are dropped — re-saves of identical content (echo
  /// from our own write) shouldn't reset state.
  ///
  /// Initial-emit race: the Android plugin (initial `store.load()` on
  /// subscribe) pushes the current blob to the event
  /// channel as soon as we `.listen()`. If we subscribed before
  /// [boot] populated `_current`, that initial emit would look like
  /// a "different owner_pk" (because current is null) and trigger a
  /// spurious `wipeAll` of the freshly-paired peer set.
  ///
  /// Defence: when `_current` is null at observation time, treat the
  /// event as the platform's initial-snapshot and *adopt without
  /// wiping*. The host should also order calls so `startWatching`
  /// runs after `boot()` whenever possible, but this guard makes the
  /// bridge correct even when the order is reversed (e.g. router
  /// boot is fire-and-forget).
  void startWatching({required Future<void> Function() onReset}) {
    _watchSub?.cancel();
    _watchSub = _store.watch().listen((incoming) async {
      final current = _current;
      if (current == null) {
        _current = incoming;
        return;
      }
      if (_bytesEqual(current.ownerPk, incoming.ownerPk)) {
        return;
      }
      _current = incoming;
      await _pairing.wipeAll();
      await onReset();
    }, onError: (Object e) {});
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _watchSub?.cancel();
    _watchSub = null;
    super.dispose();
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
