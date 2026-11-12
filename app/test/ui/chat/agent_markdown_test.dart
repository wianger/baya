// AgentMarkdown renders fenced code with a copy button.

import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, String md) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AgentMarkdown(md))),
    );
  }

  testWidgets('fenced code block shows a copy button', (tester) async {
    await pump(tester, '```dart\nfinal x = 1;\n```');
    await tester.pump();
    expect(find.byKey(const Key('code-copy')), findsOneWidget);
    expect(find.textContaining('final x = 1;'), findsOneWidget);
  });

  testWidgets('tapping copy puts the code on the clipboard', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pump(tester, '```\nhello code\n```');
    await tester.pump();
    await tester.tap(find.byKey(const Key('code-copy')));
    await tester.pump();

    expect(calls, isNotEmpty, reason: 'Clipboard.setData was invoked');
    final text = (calls.first.arguments as Map)['text'] as String;
    expect(text, contains('hello code'));
  });

  testWidgets('plain prose renders without a code block', (tester) async {
    await pump(tester, 'just a normal sentence.');
    await tester.pump();
    expect(find.byKey(const Key('code-copy')), findsNothing);
  });

  testWidgets('rich markdown respects the transcript reading width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: const AgentMarkdown(
                '# Status\n\n'
                '> The build is ready.\n\n'
                '| Check | Result |\n'
                '| --- | --- |\n'
                '| Tests | Passing |\n\n'
                '1. Keep the transcript readable.',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Tests'), findsOneWidget);
    expect(tester.getSize(find.byType(Table)).width, lessThanOrEqualTo(760));
    expect(tester.takeException(), isNull);
  });

  test('a bare localhost URL becomes a link, outside code', () {
    expect(
      linkLocalhost('Open http://localhost:5173/login.'),
      'Open <http://localhost:5173/login>.',
    );
    expect(
      linkLocalhost('(at http://localhost:3000)'),
      '(at <http://localhost:3000>)',
    );
    // Already a link, or code: as written.
    const kept = [
      '<http://localhost:5173>',
      '[app](http://localhost:5173)',
      'run `curl http://localhost:8080/health`',
      '```\ncurl http://localhost:8080\n```',
      'see https://example.com',
    ];
    for (final md in kept) {
      expect(linkLocalhost(md), md);
    }
  });

  testWidgets('GitHub alerts render titled, without their marker', (
    tester,
  ) async {
    await pump(tester, '> [!WARNING]\n> Run the tests first.');
    expect(find.textContaining('[!WARNING]'), findsNothing);
    expect(find.textContaining('Run the tests first.'), findsOneWidget);
  });
}
