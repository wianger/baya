import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildLightTheme(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('thinking is one line that opens in place', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ThinkingBlock(
          text: 'Inspect the chosen folder.',
          complete: false,
        ),
      ),
    );
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('Inspect the chosen folder.'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinking-disclosure')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('thinking-detail-text')), findsOneWidget);
    expect(find.byKey(const ValueKey('thinking-copy')), findsNothing);

    await tester.pumpWidget(
      wrap(
        const ThinkingBlock(text: 'Inspect the chosen folder.', complete: true),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Thought process'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinking-copy')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thinking-disclosure')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('thinking-detail-text')), findsNothing);
  });

  testWidgets('absent thinking content has nothing to open', (tester) async {
    await tester.pumpWidget(
      wrap(const ThinkingBlock(text: '', complete: true)),
    );
    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    expect(find.byType(SelectableText), findsNothing);
  });
}
