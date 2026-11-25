import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keep the font copyright notices available through Flutter's license page.
void registerAppFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final family in ['Inter', 'JetBrainsMono', 'PinyonScript']) {
      final text = await rootBundle.loadString('assets/fonts/$family/OFL.txt');
      yield LicenseEntryWithLineBreaks([family], text);
    }
    final symbols = await rootBundle.loadString(
      'assets/fonts/SymbolsNerdFont/LICENSE',
    );
    yield LicenseEntryWithLineBreaks(['Symbols Nerd Font'], symbols);
  });
}
