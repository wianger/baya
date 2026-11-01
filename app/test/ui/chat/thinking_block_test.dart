import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets(
    'thinking uses the shared activity row and opens supplied content',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const ThinkingBlock(
            text: 'Inspect the chosen folder.',
            complete: false,
          ),
        ),
      );
      expect(find.text('Thinking…'), findsOneWidget);
      expect(find.text('Inspect the chosen folder.'), findsOneWidget);
      expect(find.text('Reasoning'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('thinking-disclosure')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Reasoning'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('thinking-detail-text')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('thinking-detail')),
          matching: find.text('Inspect the chosen folder.'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('thinking-copy')), findsOneWidget);
      final surface = find.byKey(
        const ValueKey('thinking-content-surface'),
      );
      final surfaceRect = tester.getRect(surface);
      final copyRect = tester.getRect(
        find.byKey(const ValueKey('thinking-copy')),
      );
      expect(
        surfaceRect.contains(copyRect.topLeft) &&
            surfaceRect.contains(copyRect.bottomRight),
        isTrue,
      );
      expect(copyRect.center.dx, greaterThan(surfaceRect.center.dx));
      expect(copyRect.top, lessThan(surfaceRect.top + 40));
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Reasoning'), findsNothing);
      await tester.pumpWidget(
        wrap(
          const ThinkingBlock(
            text: 'Inspect the chosen folder.',
            complete: true,
          ),
        ),
      );
      expect(find.text('Thought process'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.byKey(const ValueKey('thinking-disclosure')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Reasoning'), findsOneWidget);
    },
  );

  testWidgets('absent thinking content has no expandable placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const ThinkingBlock(text: '', complete: true)),
    );
    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    expect(find.byType(SelectableText), findsNothing);
  });
}
