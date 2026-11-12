import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons_300.dart';

void main() {
  testWidgets('send arrow is always visible and distinct from voice input', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(onSend: sent.add, onStartAudio: () {}),
        ),
      ),
    );
    expect(find.byIcon(LucideIcons300.arrowUp), findsOneWidget);
    expect(find.byIcon(LucideIcons300.mic), findsOneWidget);
    await tester.tap(find.byKey(const Key('input-bar-action')));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await tester.enterText(find.byType(TextField), '手机文字消息');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('input-bar-action')));
    await tester.pumpAndSettle();
    expect(sent, ['手机文字消息']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.byIcon(LucideIcons300.arrowUp), findsOneWidget);
  });
}
