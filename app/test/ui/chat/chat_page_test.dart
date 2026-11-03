// The chat screen against an in-memory computer: history, header, sending,
// permission questions and session settings.

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
    expect(find.text('Claude Code · studio (WSL)'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
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
    expect(find.text('Ready'), findsOneWidget);
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

  testWidgets('a permission question is answered from the card', (
    tester,
  ) async {
    final chat = await _pump(tester);
    Object? answer;
    chat.host
        .askPermission({
          'sessionId': 's1',
          'toolCall': {
            'toolCallId': 't1',
            'title': 'rm -rf build',
            'kind': 'execute',
          },
          'options': [
            {'optionId': 'once', 'name': 'Allow', 'kind': 'allow_once'},
            {'optionId': 'no', 'name': 'Reject', 'kind': 'reject_once'},
          ],
        })
        .then((value) => answer = value);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('permission-card')), findsOneWidget);
    expect(find.text('rm -rf build'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('permission-once')));
    await tester.pumpAndSettle();
    expect(answer, {
      'outcome': {'outcome': 'selected', 'optionId': 'once'},
    });
    expect(find.byKey(const Key('permission-card')), findsNothing);
    await _finish(tester, chat);
  });

  testWidgets('session settings change the model', (tester) async {
    final chat = await _pump(tester);
    await tester.tap(find.byKey(const Key('context-usage')));
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
}
