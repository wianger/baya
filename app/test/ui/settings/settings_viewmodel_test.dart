import 'package:app/data/preferences/preferences.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/settings/states/settings_state.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

typedef _FakeStorage = MemoryStorage;

SettingsViewModel _vm(MemoryStorage storage, Preferences prefs) =>
    SettingsViewModel(storage, prefs, testHosts(MemoryStorage(), FakeHost()));

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
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

PeerRecord _peerA() => const PeerRecord(
  remoteEpk: 'epk_A',
  name: 'PC A',
  endpoint: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

void main() {
  group('SettingsViewModel', () {
    test('initial state is SettingsLoading', () {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = _vm(storage, prefs);
      expect(vm.state, isA<SettingsLoading>());
      vm.dispose();
    });

    test('empty storage → SettingsNoPeer', () async {
      final storage = _FakeStorage([]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = _vm(storage, prefs);
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<SettingsNoPeer>());
      vm.dispose();
    });

    test('peers loaded → SettingsList', () async {
      final storage = _FakeStorage([_peerA()]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = _vm(storage, prefs);
      await Future<void>.delayed(Duration.zero);

      final s = vm.state as SettingsList;
      expect(s.peers.single.remoteEpk, 'epk_A');

      vm.dispose();
    });

    test(
      'revoking the last computer deletes it and resets onboarding',
      () async {
        final storage = _FakeStorage([_peerA()]);
        final prefs = Preferences(_FakeSecureStorage());
        await prefs.setOnboardingCompleted(true);
        final vm = _vm(storage, prefs);
        await Future<void>.delayed(Duration.zero);

        await vm.revoke('epk_A');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(storage.peers, isEmpty);
        expect(prefs.onboardingCompleted, isFalse);
        expect(vm.state, isA<SettingsNoPeer>());
        vm.dispose();
      },
    );
  });
}
