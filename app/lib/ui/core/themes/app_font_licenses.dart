import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keep the font copyright notices available through Flutter's license page.
void registerAppFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final family in [
      'Geist',
      'GeistMono',
      'PinyonScript',
    ]) {
      final text = await rootBundle.loadString('assets/fonts/$family/OFL.txt');
      yield LicenseEntryWithLineBreaks([family], text);
    }
  });
}
