import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/onboarding/states/onboarding_state.dart';

/// Two-step onboarding: welcome, then pair. The pairing code carries the
/// computer's address, so there is nothing to configure by hand.
class OnboardingViewModel extends ViewModel<OnboardingState> {
  final Preferences _prefs;

  OnboardingViewModel(this._prefs) : super(const OnboardingInProgress());

  void next() {
    if (state case OnboardingInProgress(step: OnboardingStep.welcome)) {
      emit(const OnboardingInProgress(step: OnboardingStep.pair));
    }
  }

  void back() {
    if (state case OnboardingInProgress(step: OnboardingStep.pair)) {
      emit(const OnboardingInProgress());
    }
  }

  /// Pairing succeeded: leave onboarding for good.
  Future<void> completePairing() => _finish();

  /// "Scan later": Home shows how to pair from there.
  Future<void> skipPairing() => _finish();

  Future<void> _finish() async {
    await _prefs.setOnboardingCompleted(true);
    emit(const OnboardingComplete());
  }
}
