import 'dart:ui';

import 'package:app/l10n/app_localizations.dart';
import 'package:app/l10n/app_localizations_en.dart';
import 'package:flutter/widgets.dart';

export 'package:app/l10n/app_localizations.dart';

final AppLocalizations _english = AppLocalizationsEn();

extension L10nContext on BuildContext {
  /// Strings for the active locale. Falls back to English where no
  /// [Localizations] for the app exist (e.g. bare widget tests).
  AppLocalizations get l10n => AppLocalizations.of(this) ?? _english;
}

/// Strings for code without a [BuildContext] (view models, static helpers),
/// resolved from the device locale.
AppLocalizations get appL10n {
  final locale = PlatformDispatcher.instance.locale;
  return AppLocalizations.delegate.isSupported(locale)
      ? lookupAppLocalizations(locale)
      : _english;
}
