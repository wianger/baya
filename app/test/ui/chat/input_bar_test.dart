// Settings/quick-actions icon visibility in the
// chat input bar.

import 'package:app/domain/entities/agent_command.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons_300.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required bool disabled,
    required bool streaming,
    VoidCallback? onOpenQuickActions,
    void Function(String id, String raw)? onSlashCommand,
    List<AgentCommand> agentCommands = const [],
    VoidCallback? onStartAudio,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            disabled: disabled,
            streaming: streaming,
            onSend: (_) {},
            onCancel: () {},
            onOpenQuickActions: onOpenQuickActions,
            onSlashCommand: onSlashCommand,
            agentCommands: agentCommands,
            onStartAudio: onStartAudio,
          ),
        ),
      ),
    );
  }

  // The reply field occupies the upper row. The lower control row keeps the
  // model selector aligned with attach, voice, and send.
  final quickActionsKey = find.byKey(const Key('input-bar-quick-actions'));

  void expectCollapsed(WidgetTester tester) {
    if (quickActionsKey.evaluate().isEmpty) return;
    final sizeTransition = find.ancestor(
      of: quickActionsKey,
      matching: find.byType(SizeTransition),
    );
    expect(
      tester.getSize(sizeTransition).width,
      0,
      reason: 'the hidden model switcher must not occupy layout space',
    );
  }

  Future<void> openComposer(WidgetTester tester) async {
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
  }

  void expectExpanded(WidgetTester tester) {
    expect(quickActionsKey, findsOneWidget);
    final sizeTransition = find.ancestor(
      of: quickActionsKey,
      matching: find.byType(SizeTransition),
    );
    expect(
      tester.getSize(sizeTransition).width,
      greaterThan(0),
      reason: 'fully expanded when visible',
    );
  }

  testWidgets('idle, the composer is one line; in use, a card with tools', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
      onStartAudio: () {},
    );
    await tester.pumpAndSettle();
    expect(quickActionsKey, findsNothing);
    final attach = tester.getRect(find.byKey(const Key('input-bar-attach')));
    final field = tester.getRect(find.byType(TextField));
    expect(attach.right, lessThan(field.left));
    expect(attach.center.dy, closeTo(field.center.dy, 4));

    await openComposer(tester);
    expectExpanded(tester);
  });

  testWidgets('slash opens the built-in command palette and dispatches', (
    tester,
  ) async {
    String? selectedId;
    String? selectedRaw;
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onSlashCommand: (id, raw) {
        selectedId = id;
        selectedRaw = raw;
      },
    );
    await tester.enterText(find.byType(TextField), '/');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('slash-command-palette')), findsOneWidget);
    expect(find.text('New session'), findsOneWidget);
    await tester.tap(find.text('New session'));
    await tester.pumpAndSettle();
    expect(selectedId, 'new');
    expect(selectedRaw, '/new');
  });

  testWidgets('slash palette exposes skills from the active agent', (
    tester,
  ) async {
    String? selectedId;
    String? selectedRaw;
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      agentCommands: const [
        AgentCommand(
          name: 'browser',
          source: 'skill',
          description: 'Operate a browser',
        ),
      ],
      onSlashCommand: (id, raw) {
        selectedId = id;
        selectedRaw = raw;
      },
    );
    await tester.enterText(find.byType(TextField), '/bro');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(find.text('/browser'), findsOneWidget);
    expect(find.textContaining('Operate a browser'), findsOneWidget);
    await tester.tap(find.text('/browser'));
    await tester.pumpAndSettle();

    expect(selectedId, 'agent');
    expect(selectedRaw, '/browser');
  });

  testWidgets('quick actions button stays available while typing', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
      onStartAudio: () {},
    );
    await tester.enterText(find.byType(TextField), 'hello');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Model/thinking stay reachable while a draft is present.
    await tester.pumpAndSettle();
    expectExpanded(tester);
  });

  testWidgets('composer keeps reply above the attach and model control row', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
      onStartAudio: () {},
    );
    await openComposer(tester);

    final attach = tester.getRect(find.byKey(const Key('input-bar-attach')));
    final field = tester.getRect(find.byType(TextField));
    final voice = tester.getRect(find.byKey(const Key('input-bar-voice')));
    final send = tester.getRect(find.byKey(const Key('input-bar-action')));
    final model = tester.getRect(quickActionsKey);

    expect(field.bottom, lessThan(attach.top));
    expect(attach.right, lessThan(model.left));
    expect(
      attach.center.dy,
      closeTo(model.center.dy, 4),
      reason: 'attach and model share the lower control row',
    );
    expect(model.right, lessThan(voice.left));
    expect(voice.right, lessThan(send.left));
  });

  testWidgets('quick actions button hides (collapses) when disabled', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: true,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  testWidgets('quick actions button stays visible while streaming', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: true,
      onOpenQuickActions: () {},
    );
    await openComposer(tester);
    expectExpanded(tester);
  });

  // `streaming` (the whole working turn, fed by vm.isWorking) keeps
  // the composer editable for follow-ups while empty input still exposes Stop.
  testWidgets('streaming with no text shows stop and keeps typing enabled', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: true,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);
    expect(field.decoration?.hintText, isNull);
    // The composer action button uses the lighter `300` weight variants
    // (see _ComposerActionButton._icon) — match those, not the plain glyphs.
    expect(find.byIcon(LucideIcons300.square), findsOneWidget); // stop
    expect(find.byIcon(LucideIcons300.arrowUp), findsNothing);
    expect(find.byIcon(LucideIcons300.mic), findsNothing);
  });

  testWidgets('streaming + text sends a follow-up with the send button', (
    tester,
  ) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            streaming: true,
            onSend: (text) => sent = text,
            onCancel: () {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'and then this');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(find.byKey(const Key('input-bar-queue')), findsNothing);
    await tester.tap(find.byKey(const Key('input-bar-action')));
    await tester.pump();

    expect(sent, 'and then this');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
  });

  testWidgets('streaming + text queues a follow-up', (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            streaming: true,
            onSend: (text) => sent = text,
            onCancel: () {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'quick follow-up');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(find.byIcon(LucideIcons300.arrowUp), findsOneWidget);
    expect(
      find.byKey(const Key('input-bar-inline-stop')),
      findsOneWidget,
      reason: 'Stop remains reachable while the main action queues a follow-up',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, 'quick follow-up');
  });

  testWidgets('tap fires onOpenQuickActions', (tester) async {
    var tapped = 0;
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () => tapped++,
    );
    await openComposer(tester);
    await tester.tap(find.byKey(const Key('input-bar-quick-actions')));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('quick actions button stays collapsed when callback is null', (
    tester,
  ) async {
    // The button is always mounted now (so it can animate in/out); with no
    // handler `show` is false, so it collapses to zero width — hidden, but in
    // the tree. Same "hidden" contract as the typing/disabled/streaming cases.
    await pumpBar(tester, disabled: false, streaming: false);
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  // Enter is a new line from any keyboard; Ctrl+Enter sends, as the button.
  testWidgets('Enter inserts a newline; Ctrl+Enter sends', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(onSend: sent.add, onCancel: () {}),
        ),
      ),
    );

    final field = find.byType(TextField);
    await tester.enterText(field, 'line1');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, isEmpty, reason: 'Enter must not send');
    expect(tester.widget<TextField>(field).controller!.text, 'line1\n');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(sent, ['line1']);
  });

  // While there is no content, hardware Enter does nothing while streaming.
  testWidgets('hardware Enter does nothing while streaming with empty text', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(streaming: true, onSend: sent.add, onCancel: () {}),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, isEmpty);
  });

  testWidgets('an @ starting a word picks files, and gives way to them', (
    tester,
  ) async {
    var picks = 0;
    var picked = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            onSend: (_) {},
            onMention: () async {
              picks++;
              return picked;
            },
          ),
        ),
      ),
    );
    final field = find.byType(TextField);

    // Typed a key at a time, as a keyboard does.
    await tester.enterText(field, 'explain ');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(field, 'explain @');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(picks, 1);
    expect(tester.widget<TextField>(field).controller!.text, 'explain ');

    // Nothing picked: the @ stays as typed.
    picked = false;
    await tester.enterText(field, 'explain @');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(picks, 2);
    expect(tester.widget<TextField>(field).controller!.text, 'explain @');

    // Not at the start of a word: an address, not a mention.
    await tester.enterText(field, 'mail me');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(field, 'mail me@');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(picks, 2);
  });
}
