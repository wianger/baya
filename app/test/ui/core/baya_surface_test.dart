import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {bool dark = false, bool highContrast = false}) =>
    MaterialApp(
      theme: dark ? buildDarkTheme() : buildLightTheme(),
      home: MediaQuery(
        data: MediaQueryData(highContrast: highContrast),
        child: Scaffold(body: Center(child: child)),
      ),
    );

Material _material(WidgetTester tester) => tester.widget<Material>(
  find
      .descendant(of: find.byType(BayaSurface), matching: find.byType(Material))
      .first,
);

void main() {
  testWidgets('each role paints its M3 tonal container, never a blur', (
    tester,
  ) async {
    final colors = buildLightTheme().extension<AppColors>()!;
    final expected = {
      BayaSurfaceRole.card: colors.surface,
      BayaSurfaceRole.control: colors.inputFill,
      BayaSurfaceRole.content: colors.codeBg,
      BayaSurfaceRole.user: colors.userBubble,
      BayaSurfaceRole.overlay: colors.inputFill,
    };
    for (final MapEntry(key: role, value: fill) in expected.entries) {
      await tester.pumpWidget(
        _host(BayaSurface(role: role, child: const Text('x'))),
      );
      expect(_material(tester).color, fill, reason: '$role');
      expect(find.byType(BackdropFilter), findsNothing);
    }
  });

  testWidgets('only elevated overlays cast a shadow', (tester) async {
    await tester.pumpWidget(
      _host(const BayaSurface(role: BayaSurfaceRole.overlay, child: Text('x'))),
    );
    expect(_material(tester).elevation, greaterThan(0));
    await tester.pumpWidget(_host(const BayaSurface(child: Text('x'))));
    expect(_material(tester).elevation, 0);
  });

  testWidgets('high contrast and emphasis add a visible outline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const BayaSurface(child: Text('x')), highContrast: true),
    );
    final hc = _material(tester).shape! as RoundedRectangleBorder;
    expect(hc.side.width, greaterThan(0));

    await tester.pumpWidget(
      _host(const BayaSurface(emphasized: true, child: Text('x')), dark: true),
    );
    await tester.pumpAndSettle(); // the theme change animates
    final emphasized = _material(tester).shape! as RoundedRectangleBorder;
    expect(
      emphasized.side.color,
      buildDarkTheme().extension<AppColors>()!.accent,
    );
  });

  testWidgets('BayaButton is filled when prominent and tonal otherwise', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            BayaButton(onPressed: () {}, label: const Text('Primary')),
            BayaButton(
              onPressed: () {},
              prominent: false,
              label: const Text('Secondary'),
            ),
            const BayaButton(onPressed: null, label: Text('Disabled')),
          ],
        ),
      ),
    );
    expect(find.byType(FilledButton), findsNWidgets(3));
    final disabled = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Disabled'),
    );
    expect(disabled.onPressed, isNull);
  });
}
