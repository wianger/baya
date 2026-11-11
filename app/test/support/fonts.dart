import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the app's bundled fonts so golden-style screenshots show real text
/// instead of the test font's boxes.
Future<void> loadAppFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final manifest = jsonDecode(
      await rootBundle.loadString('FontManifest.json'),
    ) as List<Object?>;
    for (final entry in manifest.cast<Map<String, Object?>>()) {
      final loader = FontLoader(entry['family']! as String);
      final faces = (entry['fonts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      for (final face in faces) {
        loader.addFont(rootBundle.load(face['asset']! as String));
      }
      await loader.load();
    }
  });
}
