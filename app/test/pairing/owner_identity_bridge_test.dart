// Regression tests for OwnerIdentityBridge's watch listener — see
// Race (follow-up). The platform plugins
// emit their current blob the moment we subscribe, which used to
// race against boot()'s population of `_current` and trigger a
// spurious `wipeAll` of the freshly-loaded peer set.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/pairing/backed_up_identity_store.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:baya_identity/baya_identity.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);
  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_store);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<OwnerIdentity> _freshIdentity() async {
  final kp = await Ed25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  final sk = await kp.extractPrivateKeyBytes();
  return OwnerIdentity(
    ownerPk: Uint8List.fromList(pub.bytes),
    ownerSk: Uint8List.fromList(sk),
  );
}

/// The pre-flight reports "unavailable" while the real read/write path
/// works fine.
class _FalsePreflightStore implements OwnerIdentityStore {
  final InMemoryOwnerIdentityStore _inner;
  _FalsePreflightStore(this._inner);

  @override
  Future<bool> isSyncAvailable() async => false;
  @override
  Future<OwnerIdentity?> load() => _inner.load();
  @override
  Future<void> save(OwnerIdentity identity) => _inner.save(identity);
  @override
  Future<void> delete() => _inner.delete();
  @override
  Stream<OwnerIdentity> watch() => _inner.watch();
}

void main() {
  group('OwnerIdentityBridge.boot — pre-flight must not gate', () {
    test('boot succeeds when pre-flight is false but load/save work', () async {
      // Fresh install: no stored identity, pre-flight lies "unavailable".
      final store = _FalsePreflightStore(InMemoryOwnerIdentityStore());
      final bridge = OwnerIdentityBridge(
        store,
        PairingStorage(_FakeSecureStorage()),
      );

      final result = await bridge.boot();

      expect(result, isA<IdentityReady>());
      expect(result.generated, isTrue);
      expect(bridge.currentIdentity?.ownerPk, isNotNull);
    });

    test(
      'boot loads an existing identity even with a false pre-flight',
      () async {
        final id = await _freshIdentity();
        final store = _FalsePreflightStore(
          InMemoryOwnerIdentityStore(initial: id),
        );
        final bridge = OwnerIdentityBridge(
          store,
          PairingStorage(_FakeSecureStorage()),
        );

        final result = await bridge.boot();

        expect(result, isA<IdentityReady>());
        expect(result.generated, isFalse);
        expect(bridge.currentIdentity?.ownerPk, id.ownerPk);
      },
    );
  });

  group('BackedUpOwnerIdentityStore — backup never blocks the app', () {
    test('without Google Backup the key is kept on the phone', () async {
      final local = _FakeSecureStorage();
      final store = BackedUpOwnerIdentityStore(
        InMemoryOwnerIdentityStore(syncAvailable: false),
        local,
      );
      final bridge = OwnerIdentityBridge(
        store,
        PairingStorage(_FakeSecureStorage()),
      );

      final first = await bridge.boot();
      expect(first.generated, isTrue);
      expect(store.backedUp, isFalse);

      // Next launch finds the same key locally.
      final again = await OwnerIdentityBridge(
        BackedUpOwnerIdentityStore(
          InMemoryOwnerIdentityStore(syncAvailable: false),
          local,
        ),
        PairingStorage(_FakeSecureStorage()),
      ).boot();
      expect(again.generated, isFalse);
      expect(again.identity.ownerPk, first.identity.ownerPk);
    });

    test(
      'a restored phone adopts the Block Store key and mirrors new keys',
      () async {
        final id = await _freshIdentity();
        final restored = BackedUpOwnerIdentityStore(
          InMemoryOwnerIdentityStore(initial: id),
          _FakeSecureStorage(),
        );
        final result = await OwnerIdentityBridge(
          restored,
          PairingStorage(_FakeSecureStorage()),
        ).boot();
        expect(result.generated, isFalse);
        expect(result.identity.ownerPk, id.ownerPk);
        expect(restored.backedUp, isTrue);

        final backup = InMemoryOwnerIdentityStore();
        final fresh = BackedUpOwnerIdentityStore(backup, _FakeSecureStorage());
        final created = await OwnerIdentityBridge(
          fresh,
          PairingStorage(_FakeSecureStorage()),
        ).boot();
        expect(fresh.backedUp, isTrue);
        expect((await backup.load())!.ownerPk, created.identity.ownerPk);
      },
    );
  });

  group('OwnerIdentityBridge.startWatching — initial emit race fix', () {
    test('subscribing BEFORE boot() does NOT wipe peers (initial emit adopted '
        'silently)', () async {
      // Reproduce the production race: router calls startWatching
      // fire-and-forget before boot() has populated _current. The
      // store emits the existing blob immediately; without the fix
      // this would clear peers + trigger onReset.
      final id = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: id);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(
        const PeerRecord(
          remoteEpk: 'epk-precious',
          name: 'pi',
          endpoint: 'https://r',
          pairedAt: '2026-05-15T10:30:00Z',
        ),
      );
      final bridge = OwnerIdentityBridge(store, storage);

      var resetCalls = 0;
      bridge.startWatching(onReset: () async => resetCalls++);

      // Force the initial-emit through the in-memory store. The
      // production iOS/Android plugins do this from onListen; the
      // in-memory fake exposes the same shape via a save() that
      // echoes through the broadcast controller.
      await store.save(id);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The peer survives — no wipe happened.
      final peers = await storage.listPeers();
      expect(peers, hasLength(1));
      expect(peers.single.remoteEpk, 'epk-precious');
      // No reset callback was invoked.
      expect(resetCalls, 0);
    });

    test('after the initial emit was adopted, a *different* owner_pk DOES '
        'wipe + reset', () async {
      // Confirm the regression fix didn't soften the legitimate
      // "Owner key rotated via sync" path.
      final first = await _freshIdentity();
      final second = await _freshIdentity();
      final store = InMemoryOwnerIdentityStore(initial: first);
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(
        const PeerRecord(
          remoteEpk: 'epk-old',
          name: 'pi',
          endpoint: 'https://r',
          pairedAt: '2026-05-15T10:30:00Z',
        ),
      );
      final bridge = OwnerIdentityBridge(store, storage);

      final resetCompleter = Completer<void>();
      bridge.startWatching(
        onReset: () async {
          if (!resetCompleter.isCompleted) resetCompleter.complete();
        },
      );

      // First emit (initial) — adopted silently.
      await store.save(first);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        await storage.listPeers(),
        hasLength(1),
        reason: 'initial emit must not wipe',
      );

      // Now a real key rotation — different bytes. wipeAll fires.
      await store.save(second);
      await resetCompleter.future.timeout(const Duration(seconds: 1));
      expect(
        await storage.listPeers(),
        isEmpty,
        reason: 'real key rotation must wipe',
      );
    });

    test(
      'same-pk re-emit after adoption is a noop (no wipe, no reset)',
      () async {
        final id = await _freshIdentity();
        final store = InMemoryOwnerIdentityStore(initial: id);
        final storage = PairingStorage(_FakeSecureStorage());
        await storage.savePeer(
          const PeerRecord(
            remoteEpk: 'epk-stable',
            name: 'pi',
            endpoint: 'https://r',
            pairedAt: '2026-05-15T10:30:00Z',
          ),
        );
        final bridge = OwnerIdentityBridge(store, storage);
        var resets = 0;
        bridge.startWatching(onReset: () async => resets++);

        await store.save(id); // initial-emit adoption
        await store.save(id); // same-pk echo — must be ignored
        await store.save(id);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(await storage.listPeers(), hasLength(1));
        expect(resets, 0);
      },
    );
  });
}
