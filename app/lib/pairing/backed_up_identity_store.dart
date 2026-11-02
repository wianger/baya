import 'dart:convert';

import 'package:baya_identity/baya_identity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Owner key storage that never blocks the app.
///
/// The key always lives in Android Keystore-backed secure storage on this
/// phone. Block Store is the backup: when Google Backup and a screen lock
/// are set up, the same key is mirrored there so a new phone restores its
/// pairings. Without backup the app still works; [backedUp] tells Settings
/// to suggest turning it on.
class BackedUpOwnerIdentityStore extends ChangeNotifier
    implements OwnerIdentityStore {
  BackedUpOwnerIdentityStore(this._backup, [FlutterSecureStorage? local])
    : _local = local ?? const FlutterSecureStorage();

  static const _key = 'dev.wianger.baya.owner_identity';

  final OwnerIdentityStore _backup;
  final FlutterSecureStorage _local;
  bool _backedUp = false;

  /// Whether the key is also held by Block Store (survives a phone change).
  bool get backedUp => _backedUp;

  @override
  Future<OwnerIdentity?> load() async {
    final local = await _readLocal();
    OwnerIdentity? backup;
    try {
      backup = await _backup.load();
    } on IdentityStoreError {
      backup = null;
    }
    // A restored phone has the backup but no local copy yet.
    final identity = local ?? backup;
    if (identity == null) return null;
    if (local == null) await _writeLocal(identity);
    if (backup == null) {
      await _mirror(identity);
    } else {
      _setBackedUp(listEquals(backup.ownerPk, identity.ownerPk));
    }
    return identity;
  }

  @override
  Future<void> save(OwnerIdentity identity) async {
    await _writeLocal(identity);
    await _mirror(identity);
  }

  @override
  Stream<OwnerIdentity> watch() => _backup.watch().handleError(
    (Object _) {},
    test: (e) => e is IdentityStoreError,
  );

  @override
  Future<void> delete() async {
    await _local.delete(key: _key);
    try {
      await _backup.delete();
    } on IdentityStoreError {
      // Nothing was backed up.
    }
    _setBackedUp(false);
  }

  @override
  Future<bool> isSyncAvailable() => _backup.isSyncAvailable();

  /// Retry the backup, e.g. after the user enabled Google Backup.
  Future<bool> retryBackup() async {
    final identity = await _readLocal();
    if (identity != null) await _mirror(identity);
    return _backedUp;
  }

  Future<void> _mirror(OwnerIdentity identity) async {
    try {
      await _backup.save(identity);
      _setBackedUp(true);
    } on IdentityStoreError {
      _setBackedUp(false);
    }
  }

  Future<OwnerIdentity?> _readLocal() async {
    final raw = await _local.read(key: _key);
    if (raw == null) return null;
    try {
      return OwnerIdentity.fromBlob(base64.decode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeLocal(OwnerIdentity identity) =>
      _local.write(key: _key, value: base64.encode(identity.toBlob()));

  void _setBackedUp(bool value) {
    if (_backedUp == value) return;
    _backedUp = value;
    notifyListeners();
  }
}
