// Sealed state for OnboardingViewModel. Switch exhaustively in
// OnboardingPage.build().

/// Welcome, then scan. The relay comes from the pairing QR.
enum OnboardingStep { welcome, pair }

sealed class OnboardingState {
  const OnboardingState();
}

class OnboardingInProgress extends OnboardingState {
  final OnboardingStep step;
  const OnboardingInProgress({this.step = OnboardingStep.welcome});

  @override
  bool operator ==(Object other) =>
      other is OnboardingInProgress && other.step == step;

  @override
  int get hashCode => step.hashCode;
}

class OnboardingComplete extends OnboardingState {
  const OnboardingComplete();
}
