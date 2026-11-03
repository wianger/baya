// Pairing storage: PeerRecord JSON, cached session lists, wipeAll.

import 'package:app/acp/acp.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  void seed(String key, String value) => _store[key] = value;

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
  }) async => Map.from(_store);

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.clear();

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.containsKey(key);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('PeerRecord', () {
    test('round-trips through JSON', () {
      const record = PeerRecord(
        remoteEpk: 'pk_ed25519',
        name: 'studio (WSL)',
        endpoint: 'https://studio.tail.ts.net/baya-pair/wsl/direct',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      final json = record.toJson();
      expect(json['remote_epk'], 'pk_ed25519');
      expect(json['name'], 'studio (WSL)');
      expect(json['nickname'], isNull);
      expect(PeerRecord.fromJson(json), record);
    });

    test('the nickname wins as label; copyWith(nickname: null) clears it', () {
      const record = PeerRecord(
        remoteEpk: 'pk1',
        name: 'studio',
        endpoint: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
        nickname: 'Home',
      );
      expect(record.label, 'Home');
      expect(PeerRecord.fromJson(record.toJson()).nickname, 'Home');
      final cleared = record.copyWith(nickname: null);
      expect(cleared.nickname, isNull);
      expect(cleared.label, 'studio');
      expect(record.copyWith(name: 'new').nickname, 'Home');
    });

    test('save, load, list and delete through secure storage', () async {
      final storage = PairingStorage(_FakeSecureStorage());
      const r = PeerRecord(
        remoteEpk: 'epk1',
        name: 'pc',
        endpoint: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      await storage.savePeer(r);
      expect((await storage.loadPeer('epk1'))?.name, 'pc');
      expect(await storage.listPeers(), hasLength(1));
      await storage.deletePeer('epk1');
      expect(await storage.listPeers(), isEmpty);
    });
  });

  group('session lists', () {
    test('cache a computer\'s sessions', () async {
      final storage = PairingStorage(_FakeSecureStorage());
      const session = SessionSummary(
        sessionId: 's1',
        cwd: '/code/app',
        title: 'Fix the bug',
        agent: 'claude',
        agentName: 'Claude Code',
        working: true,
      );
      await storage.saveSessions('epk1', [session]);
      expect(await storage.loadSessions('epk1'), [session]);
      await storage.deleteSessions('epk1');
      expect(await storage.loadSessions('epk1'), isEmpty);
    });
  });

  group('PairingStorage.wipeAll', () {
    test('clears every peer and every cached session list', () async {
      final storage = PairingStorage(_FakeSecureStorage());
      for (final key in ['epk-a', 'epk-b']) {
        await storage.savePeer(
          PeerRecord(
            remoteEpk: key,
            name: key,
            endpoint: 'ws://x',
            pairedAt: '2026-01-01T00:00:00Z',
          ),
        );
      }
      await storage.saveSessions('epk-a', const [
        SessionSummary(
          sessionId: 's',
          cwd: '/',
          title: 't',
          agent: 'a',
          agentName: 'A',
        ),
      ]);
      await storage.wipeAll();
      expect(await storage.listPeers(), isEmpty);
      expect(await storage.loadSessions('epk-a'), isEmpty);
    });

    test('notifies listeners exactly once', () async {
      final storage = PairingStorage(_FakeSecureStorage());
      var notifications = 0;
      storage.addListener(() => notifications++);
      await storage.wipeAll();
      expect(notifications, 1);
    });
  });
}
