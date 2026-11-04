import 'dart:async';

import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/ui/transfer/transfer_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<BuildContext> _host(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (c) {
          context = c;
          return const Scaffold();
        },
      ),
    ),
  );
  return context;
}

void main() {
  testWidgets('progress shows while it runs and closes when done', (
    tester,
  ) async {
    final context = await _host(tester);
    final step = Completer<void>();
    final result = runTransfer<String>(
      context,
      title: 'Sending to the computer',
      task: (progress, label, control) async {
        label('notes.pdf');
        progress(512 * 1024, 2 * 1024 * 1024);
        await step.future;
        return 'done';
      },
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transfer-progress')), findsOneWidget);
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.text('512 KB / 2.0 MB'), findsOneWidget);

    step.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transfer-progress')), findsNothing);
    expect(await result, 'done');
  });

  testWidgets('cancel closes at once and stops at the next piece', (
    tester,
  ) async {
    final context = await _host(tester);
    final step = Completer<void>();
    late TransferControl seen;
    final result = runTransfer<String>(
      context,
      title: 'Receiving from the computer',
      task: (progress, label, control) async {
        seen = control;
        await step.future;
        if (control.cancelled) throw const TransferCancelled();
        return 'late';
      },
    );
    // Nothing known yet: the bar runs indeterminate, so pump, don't settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('transfer-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transfer-progress')), findsNothing);
    expect(seen.cancelled, isTrue);
    expect(await result, isNull);
    step.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a failure is said', (tester) async {
    final context = await _host(tester);
    final result = runTransfer<String>(
      context,
      title: 'Sending to the computer',
      task: (progress, label, control) async => throw Exception('disk full'),
    );
    await tester.pumpAndSettle();
    expect(find.text("The file didn't get through"), findsOneWidget);
    expect(find.textContaining('disk full'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  test('sizes read as people say them', () {
    expect(formatBytes(900), '900 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
  });
}
