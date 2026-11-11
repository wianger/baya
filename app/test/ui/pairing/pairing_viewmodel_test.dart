// Tests for PairingViewModel: scan → `_baya/pair` → paired, against an
// in-memory computer.

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/host_socket.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/pairing/states/pairing_state.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:baya_identity/baya_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/acp_harness.dart';

/// In-memory fake of FlutterSecureStorage so Preferences can be
/// constructed in tests without touching the platform channel.
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
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PrefsForTest extends Preferences {
  _PrefsForTest() : super(_FakeSecureStorage());
}

typedef _FakeStorage = MemoryStorage;

/// Helper: build a fully-booted [OwnerIdentityBridge] backed by an
/// in-memory plugin store, seeded with a freshly-generated identity.
/// Mirrors what `dependencies.dart` + the router's _BootState do before
/// PairingViewModel runs in production.
Future<OwnerIdentityBridge> _bootedBridge(PairingStorage storage) async {
  final store = InMemoryOwnerIdentityStore();
  final bridge = OwnerIdentityBridge(store, storage);
  await bridge.boot();
  return bridge;
}

const _qrUri =
    'baya://pair?t=AAAAAAAAAAAAAAAAAAAAAA&'
    'epk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&'
    'e=https%3A%2F%2Fpc.tail1.ts.net%2Fbaya-pair%2Fwsl%2Fdirect&'
    'n=studio+%28WSL%29';

/// A computer whose `_baya/pair` answers with [result] or fails with [error].
HostSocketFactory _computer({Object? result, RpcError? error}) {
  final host = FakeHost();
  host.handlers['_baya/pair'] = (_) {
    if (error != null) throw error;
    return result ?? {'hostname': 'studio'};
  };
  return host.connect;
}

HostSocketFactory _unreachable() =>
    ({required endpoint, required hostKey, required identity}) async =>
        throw Exception('socket exception');

// ---------------------------------------------------------------------------
// Unit tests — PairingViewModel
// ---------------------------------------------------------------------------

void main() {
  group('PairingViewModel', () {
    test('initial state is PairingScanning', () async {
      final storage = _FakeStorage();
      final bridge = await _bootedBridge(storage);
      final vm = PairingViewModel(
        storage,
        _unreachable(),
        _PrefsForTest(),
        bridge,
      );
      expect(vm.state, isA<PairingScanning>());
      vm.dispose();
    });

    test('a QR that is not a pairing code explains itself', () async {
      final storage = _FakeStorage();
      final bridge = await _bootedBridge(storage);
      final vm = PairingViewModel(
        storage,
        _unreachable(),
        _PrefsForTest(),
        bridge,
      );
      await vm.onQrScanned('https://example.com/not-a-qr');
      expect(vm.state, isA<PairingError>());
      vm.retry();
      await vm.onQrScanned('baya://pair?t=AAAA');
      expect((vm.state as PairingError).message, contains('incomplete'));
      vm.dispose();
    });

    test('scan → connecting → paired', () async {
      final storage = _FakeStorage();
      final bridge = await _bootedBridge(storage);
      final prefs = _PrefsForTest();
      final vm = PairingViewModel(storage, _computer(), prefs, bridge);

      final fut = vm.onQrScanned(_qrUri);
      expect(vm.state, isA<PairingConnecting>());
      await fut;

      expect(vm.state, isA<PairingPaired>());
      expect((vm.state as PairingPaired).hostnameHint, 'studio');
      expect(storage.peers.single.name, 'studio (WSL)');
      expect(
        prefs.tailnetDomain,
        'tail1.ts.net',
        reason: 'the tailnet completes short names next time',
      );
      vm.dispose();
    });

    test('a refused code → PairingError(canRetry: true)', () async {
      final storage = _FakeStorage();
      final bridge = await _bootedBridge(storage);
      final vm = PairingViewModel(
        storage,
        _computer(
          error: const RpcError(-32000, 'expired', {'reason': 'token_expired'}),
        ),
        _PrefsForTest(),
        bridge,
      );

      await vm.onQrScanned(_qrUri);

      final err = vm.state as PairingError;
      expect(err.canRetry, isTrue);
      expect(err.message, contains('QR expired'));
      expect(storage.peers, isEmpty);
      vm.dispose();
    });

    test(
      'transport failure → PairingError + retry returns to scanning',
      () async {
        final storage = _FakeStorage();
        final bridge = await _bootedBridge(storage);
        final vm = PairingViewModel(
          storage,
          _unreachable(),
          _PrefsForTest(),
          bridge,
        );

        await vm.onQrScanned(_qrUri);
        expect(vm.state, isA<PairingError>());
        expect((vm.state as PairingError).canRetry, isTrue);

        vm.retry();
        expect(vm.state, isA<PairingScanning>());

        vm.dispose();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Widget harness test — page reacts to ViewModel state changes
  // -------------------------------------------------------------------------

  group('PairingPage widget', () {
    testWidgets('shows Done after pairing', (tester) async {
      final storage = _FakeStorage();
      final bridge = await _bootedBridge(storage);
      final vm = PairingViewModel(
        storage,
        _computer(),
        _PrefsForTest(),
        bridge,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider.value(
            value: vm,
            child: _PairingPageTestHarness(vm: vm),
          ),
        ),
      );
      await tester.runAsync(() => vm.onQrScanned(_qrUri));
      await tester.pump();

      expect(vm.state, isA<PairingPaired>());
      expect(find.text('Done'), findsOneWidget);
      vm.dispose();
    });

    testWidgets('shows the error view and retries', (tester) async {
      final storage = _FakeStorage();
      final bridge = await _bootedBridge(storage);
      final vm = PairingViewModel(
        storage,
        _computer(
          error: const RpcError(-32000, 'used', {'reason': 'token_consumed'}),
        ),
        _PrefsForTest(),
        bridge,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider.value(
            value: vm,
            child: _PairingPageTestHarness(vm: vm),
          ),
        ),
      );
      await tester.runAsync(() => vm.onQrScanned(_qrUri));
      await tester.pump();

      expect(vm.state, isA<PairingError>());
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(vm.state, isA<PairingScanning>());
      vm.dispose();
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal widget harness that renders PairingState without MobileScanner
// ---------------------------------------------------------------------------

class _PairingPageTestHarness extends StatelessWidget {
  final PairingViewModel vm;
  const _PairingPageTestHarness({required this.vm});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PairingViewModel>().state;

    return Scaffold(
      body: switch (state) {
        PairingIdle() => const Text('Idle'),
        PairingScanning() => const Text('Scanning'),
        PairingConnecting() => const Text('Connecting…'),
        PairingPaired() => const Text('Done'),
        PairingError(:final message) => Column(
          children: [
            Text(message),
            ElevatedButton(onPressed: vm.retry, child: const Text('Try again')),
          ],
        ),
      },
    );
  }
}
