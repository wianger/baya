import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/onboarding/states/onboarding_state.dart';
import 'package:app/ui/onboarding/viewmodels/onboarding_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStore implements FlutterSecureStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _m[key];
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
      _m.remove(key);
    } else {
      _m[key] = value;
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
  }) async => _m.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<({Preferences prefs, OnboardingViewModel vm})> _setup() async {
  final prefs = Preferences(_FakeStore());
  final vm = OnboardingViewModel(prefs);
  return (prefs: prefs, vm: vm);
}

void main() {
  group('OnboardingViewModel', () {
    test('starts on welcome and moves to pairing', () async {
      final (:prefs, :vm) = await _setup();
      expect(vm.state, const OnboardingInProgress());
      vm.next();
      expect(vm.state, const OnboardingInProgress(step: OnboardingStep.pair));
      vm.next();
      expect(vm.state, const OnboardingInProgress(step: OnboardingStep.pair));
      vm.back();
      expect(vm.state, const OnboardingInProgress());
      expect(
        prefs.relayUrl,
        isNull,
        reason: 'onboarding never asks for a relay',
      );
    });

    test('pairing or skipping completes onboarding', () async {
      for (final finish in [
        (OnboardingViewModel vm) => vm.completePairing(),
        (OnboardingViewModel vm) => vm.skipPairing(),
      ]) {
        final (:prefs, :vm) = await _setup();
        vm.next();
        await finish(vm);
        expect(vm.state, isA<OnboardingComplete>());
        expect(prefs.onboardingCompleted, isTrue);
      }
    });
  });
}
