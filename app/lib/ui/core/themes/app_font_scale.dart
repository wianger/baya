import 'package:app/l10n/l10n.dart';

/// User-selectable text size.
///
/// The system font size changes every app; this gives Baya its own knob.
///
/// The factor is applied as a `TextScaler` on the `MediaQuery` above the router
/// rather than by multiplying `AppTypography`'s base sizes. That covers the
/// per-widget `copyWith(fontSize: …)` call sites too — multiplying the base
/// styles would leave every one-off size unscaled, which is most of the chat.
enum AppFontScale {
  small('Small', 0.9),
  standard('Default', 1.0),
  large('Large', 1.15),
  extraLarge('XL', 1.3);

  const AppFontScale(this.label, this.factor);

  /// English label; the UI uses [localizedLabel].
  final String label;

  String localizedLabel(AppLocalizations l10n) => switch (this) {
    small => l10n.fontSmall,
    standard => l10n.fontDefault,
    large => l10n.fontLarge,
    extraLarge => label,
  };

  /// Multiplier applied to every text size in the app.
  final double factor;

  /// Parse a persisted value. Unknown/legacy/missing → [standard], so a bad
  /// stored string can never leave the app with unreadable text.
  static AppFontScale fromName(String? raw) {
    for (final v in AppFontScale.values) {
      if (v.name == raw) return v;
    }
    return AppFontScale.standard;
  }
}
