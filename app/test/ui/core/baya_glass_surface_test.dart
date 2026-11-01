import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'high contrast keeps controls opaque and operable in both themes',
    (tester) async {
      for (final dark in [false, true]) {
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? buildDarkTheme() : buildLightTheme(),
            home: MediaQuery(
              data: const MediaQueryData(highContrast: true),
              child: Scaffold(
                body: Center(
                  child: BayaGlassSurface(
                    child: TextButton(
                      onPressed: () => taps++,
                      child: const Text('Choose workspace'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(BackdropFilter), findsNothing);
        final opaque = tester
            .widgetList<DecoratedBox>(
              find.descendant(
                of: find.byType(BayaGlassSurface),
                matching: find.byType(DecoratedBox),
              ),
            )
            .where((box) => (box.decoration as BoxDecoration).color != null);
        expect(opaque, isNotEmpty);
        expect((opaque.first.decoration as BoxDecoration).color!.a, 1);
        await tester.tap(find.text('Choose workspace'));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('only the functional layer uses backdrop blur', (tester) async {
    const blurredRoles = {
      BayaGlassRole.navigation,
      BayaGlassRole.control,
      BayaGlassRole.overlay,
    };
    for (final role in BayaGlassRole.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: Center(
              child: BayaGlassSurface(
                role: role,
                child: const SizedBox(width: 96, height: 48),
              ),
            ),
          ),
        ),
      );

      final usesBlur = blurredRoles.contains(role);
      expect(
        find.byType(BackdropFilter),
        usesBlur ? findsOneWidget : findsNothing,
        reason: '$role',
      );
      expect(
        find.byKey(const ValueKey('baya-glass-rim')),
        usesBlur ? findsOneWidget : findsNothing,
        reason: '$role',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('non-elevated overlays are quiet opaque panels', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(
          body: Center(
            child: BayaGlassSurface(
              role: BayaGlassRole.overlay,
              elevated: false,
              child: SizedBox(width: 96, height: 48),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(const ValueKey('baya-glass-rim')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('brand tile uses a crisp opaque tile', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: const Scaffold(
          body: Center(child: AppMark(size: 96, tile: true)),
        ),
      ),
    );

    expect(find.byType(BayaGlassSurface), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(const ValueKey('baya-glass-rim')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('high contrast mode uses an opaque semantic surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const MediaQuery(
          data: MediaQueryData(highContrast: true),
          child: Scaffold(
            body: Center(
              child: BayaGlassSurface(child: SizedBox(width: 96, height: 48)),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('primary action buttons use a solid accent fill', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Center(
            child: BayaGlassButton(
              buttonKey: const Key('glass-button'),
              onPressed: () => taps++,
              icon: const Icon(Icons.add),
              label: const Text('New session'),
            ),
          ),
        ),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      button.style!.backgroundColor!.resolve(<WidgetState>{}),
      buildLightTheme().extension<AppColors>()!.accent,
    );
    expect(find.byType(BayaGlassSurface), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.tap(find.byKey(const Key('glass-button')));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled action buttons retain an accessible solid surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: const Scaffold(
          body: Center(
            child: BayaGlassButton(onPressed: null, label: Text('Save')),
          ),
        ),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.byType(BayaGlassSurface), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0.58,
    );
    expect(tester.takeException(), isNull);
  });
}
