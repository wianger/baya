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
    // The thought streams through a short scrolling window.
    expect(find.byKey(const ValueKey('thinking-window')), findsOneWidget);
    expect(find.text('Inspect the chosen folder.'), findsOneWidget);
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

  testWidgets('a long thought keeps its newest line in view', (tester) async {
    final lines = [for (var i = 1; i <= 40; i++) 'Step $i of the plan.'];
    await tester.pumpWidget(
      wrap(ThinkingBlock(text: lines.take(5).join('\n'), complete: false)),
    );
    await tester.pumpWidget(
      wrap(ThinkingBlock(text: lines.join('\n'), complete: false)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final window = tester.getRect(
      find.byKey(const ValueKey('thinking-window')),
    );
    expect(window.height, lessThan(140));
    final scroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byKey(const ValueKey('thinking-window')),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    final position = scroll.controller!.position;
    expect(position.pixels, position.maxScrollExtent);
    expect(position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('absent thinking content has nothing to open', (tester) async {
    await tester.pumpWidget(
      wrap(const ThinkingBlock(text: '', complete: true)),
    );
    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    expect(find.byType(SelectableText), findsNothing);
  });
}
