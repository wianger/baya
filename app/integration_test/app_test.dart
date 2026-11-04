// Runs the real app on a device or emulator:
//   flutter test integration_test
import 'package:app/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a fresh install starts at onboarding and moves on', (tester) async {
    app.main();
    for (var i = 0; i < 100 && find.text('Get started').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Get started'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Get started'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
