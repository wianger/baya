// The chat screen against an in-memory computer: history, header, sending,
// permission questions and session settings.

import 'dart:async';

import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/acp_harness.dart';

class _Speech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Stream<double> get soundLevel => const Stream.empty();
  @override
  void dispose() {}
}

class _Picker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FakeHost _computer() => FakeHost(sessions: [testSession(title: 'Fix login')])
  ..history['s1'] = [
    {
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': 'Why does login fail?'},
      'messageId': 'm0',
    },
    {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': 'The token expired.'},
    },
    {'sessionUpdate': 'usage_update', 'used': 40000, 'size': 200000},
  ]
  ..setup = {
    'configOptions': [
      {
        'id': 'model',
        'name': 'Model',
        'category': 'model',
        'type': 'select',
        'currentValue': 'opus',
        'options': [
          {'value': 'opus', 'name': 'Opus'},
          {'value': 'sonnet', 'name': 'Sonnet'},
        ],
      },
    ],
    '_meta': {
      'baya': {'agentName': 'Claude Code'},
    },
  };

class _Chat {
  _Chat(this.host, this.hosts, this.session, this.prefs);
  final FakeHost host;
  final Hosts hosts;
  final SessionController session;
  final Preferences prefs;

  void dispose() {
    session.dispose();
    hosts.dispose();
    prefs.dispose();
  }
}

Future<_Chat> _pump(
  WidgetTester tester, {
  FakeHost? computer,
  double width = 412,
  double textScale = 1,
}) async {
  // A phone's height: the composer's card needs the room.
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = Preferences();
  await prefs.load();
  final host = computer ?? _computer();
  final storage = MemoryStorage([testPeer(name: 'studio (WSL)')]);
  final hosts = testHosts(storage, host);
  await hosts.start();
  await pumpOnline(tester, hosts);
  final session = SessionController(hosts.all.single, 's1');
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<SessionController>.value(value: session),
          ChangeNotifierProvider<Preferences>.value(value: prefs),
          ChangeNotifierProvider(create: (_) => SessionSelection()),
          ChangeNotifierProvider(create: (_) => VoiceInputViewModel(_Speech())),
          ChangeNotifierProvider(create: (_) => AttachmentViewModel(_Picker())),
        ],
        child: Scaffold(
          body: SizedBox(width: width, child: const ChatPage()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Chat(host, hosts, session, prefs);
}

Future<void> _finish(WidgetTester tester, _Chat chat) async {
  await tester.pumpWidget(const SizedBox());
  chat.dispose();
  await tester.pump();
}

void main() {
  testWidgets('shows the replayed history, title, agent and computer', (
    tester,
  ) async {
    final chat = await _pump(tester);
    expect(find.text('Fix login'), findsOneWidget);
    // DeepSeek's header: the title alone; no status dot while ready.
    expect(find.byKey(const Key('chat-status-dot')), findsNothing);
    expect(find.text('Why does login fail?'), findsOneWidget);
    expect(find.text('The token expired.'), findsOneWidget);
    // The context ring shows the agent's usage.
    expect(find.text('20%'), findsOneWidget);
    await _finish(tester, chat);
  });

  testWidgets('the header fits a narrow window with large text', (
    tester,
  ) async {
    final chat = await _pump(tester, width: 320, textScale: 1.3);
    expect(tester.takeException(), isNull);
    expect(find.text('Fix login'), findsOneWidget);
    await _finish(tester, chat);
  });

  testWidgets('without branching, edit goes straight to the composer', (
    tester,
  ) async {
    final chat = await _pump(tester);
    await tester.tap(find.byKey(const Key('user-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Branch from here'), findsNothing);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-floating-composer')),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, 'Why does login fail?');
    await _finish(tester, chat);
  });

  testWidgets('sending a prompt shows the reply', (tester) async {
    final chat = await _pump(tester);
    chat.host.reply = [
      {
        'sessionUpdate': 'agent_message_chunk',
        'content': {'type': 'text', 'text': 'Refreshed the token.'},
      },
    ];
    await tester.enterText(find.byType(TextField), 'Fix it');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    await tester.tap(find.byKey(const Key('input-bar-action')));
    await tester.pumpAndSettle();
    expect(find.text('Fix it'), findsOneWidget);
    expect(find.text('Refreshed the token.'), findsOneWidget);
    final prompt = chat.host.calls.lastWhere(
      (c) => c.method == 'session/prompt',
    );
    expect(prompt.params['sessionId'], 's1');
    await _finish(tester, chat);
  });

  testWidgets('session settings change the model', (tester) async {
    final chat = await _pump(tester);
    await _openComposer(tester);
    await tester.tap(find.byKey(const Key('input-bar-quick-actions')));
    await tester.pumpAndSettle();
    expect(find.text('Opus'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('setting-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('choice-sonnet')));
    await tester.pumpAndSettle();
    final change = chat.host.calls.lastWhere(
      (c) => c.method == 'session/set_config_option',
    );
    expect(change.params, {
      'sessionId': 's1',
      'configId': 'model',
      'value': 'sonnet',
    });
    await _finish(tester, chat);
  });

  testWidgets('files picked from the folder go with the next prompt', (
    tester,
  ) async {
    final computer = _computer();
    computer.handlers['_baya/files'] = (params) => {
      'path': '/home/me/web',
      'parent': '/home/me',
      'entries': [
        {'name': 'src', 'path': '/home/me/web/src', 'type': 'directory'},
        {'name': 'app.ts', 'path': '/home/me/web/app.ts', 'type': 'file'},
      ],
    };
    final chat = await _pump(tester, computer: computer);
    await tester.tap(find.byKey(const Key('input-bar-attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-app.ts')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('file-picker-done')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('attached-file:///home/me/web/app.ts')),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'Look at this');
    // The composer opens into its card.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    await tester.tap(find.byKey(const Key('input-bar-action')));
    await tester.pumpAndSettle();
    final prompt = computer.calls.lastWhere(
      (c) => c.method == 'session/prompt',
    );
    expect((prompt.params['prompt'] as List).last, {
      'type': 'resource_link',
      'name': 'app.ts',
      'uri': 'file:///home/me/web/app.ts',
    });
    expect(chat.session.attachedFiles, isEmpty);
    await _finish(tester, chat);
  });

  testWidgets('the context ring shows only the context', (tester) async {
    final chat = await _pump(tester);
    await tester.tap(find.byKey(const Key('context-usage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('context-sheet')), findsOneWidget);
    expect(find.text('20.0%'), findsOneWidget);
    expect(find.byKey(const ValueKey('setting-model')), findsNothing);
    await _finish(tester, chat);
  });

  testWidgets('the composer chip names the model and opens its settings', (
    tester,
  ) async {
    final chat = await _pump(tester);
    await _openComposer(tester);
    expect(find.text('Opus'), findsOneWidget);
    await tester.tap(find.byKey(const Key('input-bar-quick-actions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setting-model')), findsOneWidget);
    await _finish(tester, chat);
  });
}

/// Claude's composer is one line until used: a tap opens it to its tools.
Future<void> _openComposer(WidgetTester tester) async {
  await tester.tap(find.byType(TextField));
  await tester.pumpAndSettle();
}
