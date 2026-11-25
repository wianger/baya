import 'package:app/ui/core/branding/baya_intro.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the opening plays over the app, then gives way to it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        builder: (context, child) => BayaIntro(child: child!),
        home: const Scaffold(body: Center(child: Text('home'))),
      ),
    );
    // Every frame of it builds without an error (a failed build shows
    // Flutter's grey error box in a release).
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
    expect(find.byKey(const Key('baya-intro')), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('it starts with the bird alone, where Android left it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        builder: (context, child) => BayaIntro(child: child!),
        home: const Scaffold(),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('baya-intro')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
