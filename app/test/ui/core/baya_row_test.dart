import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  Widget row({required bool spinning, bool reduceMotion = false}) =>
      MaterialApp(
        theme: buildDarkTheme(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: BayaRow(
              label: 'Session',
              icon: LucideIcons.loaderCircle,
              spinning: spinning,
            ),
          ),
        ),
      );

  double turns(WidgetTester tester) => tester
      .widget<RotationTransition>(
        find.descendant(
          of: find.byType(BayaRow),
          matching: find.byType(RotationTransition),
        ),
      )
      .turns
      .value;

  testWidgets('a working row turns its icon', (tester) async {
    await tester.pumpWidget(row(spinning: true));
    await tester.pump(const Duration(milliseconds: 250));
    expect(turns(tester), closeTo(.25, .02));
  });

  testWidgets('it stops when the work ends', (tester) async {
    await tester.pumpWidget(row(spinning: true));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(row(spinning: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(turns(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('it stays still when the system asks for less motion', (
    tester,
  ) async {
    await tester.pumpWidget(row(spinning: true, reduceMotion: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(turns(tester), 0);
  });
}
