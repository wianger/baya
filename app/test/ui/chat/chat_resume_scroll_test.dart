// The chat keeps scrolling after the phone sleeps and wakes: the connection
// drops and catches up, touches go missing, the window insets change.

import 'dart:async';

import 'package:app/acp/json_rpc.dart';
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
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return _Chat(host, hosts, session, prefs);
}

List<Json> _history() => [
  for (var i = 0; i < 40; i++) ...[
    {
      'sessionUpdate': 'user_message_chunk',
      'content': {'type': 'text', 'text': 'Question $i'},
      'messageId': 'm$i',
    },
    {
      'sessionUpdate': 'agent_message_chunk',
      'content': {'type': 'text', 'text': 'Answer $i. ' * 30},
      'messageId': 'a$i',
    },
  ],
];

FakeHost _long({required bool resumable}) {
  final host = _computer();
  host.history['s1'] = _history();
  if (resumable) {
    host.setup = {
      ...host.setup,
      '_meta': {
        'baya': {
          'agentName': 'Claude Code',
          'cursor': {'epoch': 'e1', 'seq': 0},
          'resumed': false,
        },
      },
    };
  }
  return host;
}

double _offset(WidgetTester tester) => tester
    .widget<ListView>(find.byKey(const ValueKey('chat-message-scroll')))
    .controller!
    .offset;

Future<void> _expectScrolls(WidgetTester tester) async {
  final before = _offset(tester);
  await tester.drag(
    find.byKey(const ValueKey('chat-message-scroll')),
    const Offset(0, 300),
  );
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(_offset(tester), greaterThan(before + 100));
}

void _sleepAndWake(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets(
    'a row held by a touch, scrolled away, survives the screen waking',
    (tester) async {
      final chat = await _pump(tester, computer: _long(resumable: true));
      addTearDown(chat.dispose);
      // A finger rests on a message: its ink highlight keeps the row alive.
      final inks = find.descendant(
        of: find.byKey(const ValueKey('chat-message-scroll')),
        matching: find.byType(InkWell),
      );
      expect(inks, findsWidgets);
      final held = await tester.startGesture(tester.getCenter(inks.first));
      await tester.pump(const Duration(milliseconds: 200));
      // A second finger scrolls the row out of view.
      for (var i = 0; i < 6; i++) {
        await tester.drag(
          find.byKey(const ValueKey('chat-message-scroll')),
          const Offset(0, 400),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      // The screen wakes: insets change and the history comes again.
      _sleepAndWake(tester);
      tester.view.padding = const FakeViewPadding(top: 30, bottom: 20);
      addTearDown(tester.view.resetPadding);
      chat.host.socket!.drop();
      await tester.pump(const Duration(seconds: 1));
      chat.hosts.all.single.reconnectNow();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await held.up();
      await _expectScrolls(tester);
    },
  );

  testWidgets(
    'coming back to a working session mid-turn keeps the page alive',
    (tester) async {
      final host = _long(resumable: true);
      host.sessions
        ..clear()
        ..add(testSession(title: 'Fix login', working: true));
      var seq = 0;
      Json numbered(Json update) => {
        'sessionId': 's1',
        'update': update,
        '_meta': {
          'baya': {'seq': ++seq},
        },
      };
      final chat = await _pump(tester, computer: host);
      addTearDown(chat.dispose);
      void stream(int round) {
        host.push(
          'session/update',
          numbered({
            'sessionUpdate': 'agent_thought_chunk',
            'content': {'type': 'text', 'text': 'thinking $round '},
          }),
        );
        host.push(
          'session/update',
          numbered({
            'sessionUpdate': 'tool_call',
            'toolCallId': 't$round',
            'title': 'Run tests $round',
            'kind': 'execute',
            'status': 'in_progress',
          }),
        );
        host.push(
          'session/update',
          numbered({
            'sessionUpdate': 'tool_call_update',
            'toolCallId': 't$round',
            'status': 'completed',
            'content': [
              {
                'type': 'content',
                'content': {'type': 'text', 'text': 'ok $round'},
              },
            ],
          }),
        );
        host.push(
          'session/update',
          numbered({
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'Step $round done. '},
          }),
        );
      }

      for (var i = 0; i < 3; i++) {
        stream(i);
        await tester.pump(const Duration(milliseconds: 50));
      }
      _sleepAndWake(tester);
      chat.host.socket!.drop();
      await tester.pump(const Duration(seconds: 1));
      host.handlers['session/load'] = (_) {
        for (var i = 3; i < 8; i++) {
          stream(i);
        }
        return {
          ...host.setup,
          '_meta': {
            'baya': {
              'agentName': 'Claude Code',
              'cursor': {'epoch': 'e1', 'seq': seq},
              'resumed': true,
            },
          },
        };
      };
      chat.hosts.all.single.reconnectNow();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (i.isEven) stream(100 + i);
      }
      expect(tester.takeException(), isNull);
      await _expectScrolls(tester);
    },
  );

  testWidgets('a touch the screen-off swallowed does not freeze scrolling', (
    tester,
  ) async {
    final chat = await _pump(tester, computer: _long(resumable: true));
    addTearDown(chat.dispose);
    // A finger on the list when the screen goes off: Android never sends
    // its lift.
    final stuck = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('chat-message-scroll'))),
    );
    await stuck.moveBy(const Offset(0, 40));
    await stuck.moveBy(const Offset(0, 40));
    await tester.pump();
    _sleepAndWake(tester);
    // The history changes meanwhile, which ends the scroll in progress.
    chat.host.socket!.drop();
    await tester.pump(const Duration(seconds: 1));
    chat.hosts.all.single.reconnectNow();
    await tester.pumpAndSettle();
    await _expectScrolls(tester);
  });

  for (final resumable in [false, true]) {
    testWidgets(
      'the chat still scrolls after coming back (resumable: $resumable)',
      (tester) async {
        final chat = await _pump(tester, computer: _long(resumable: resumable));
        addTearDown(chat.dispose);
        await _expectScrolls(tester);

        // The phone sleeps: the connection drops, then comes back and the
        // history is sent again.
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        chat.host.socket!.drop();
        await tester.pump(const Duration(seconds: 1));
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        chat.hosts.all.single.reconnectNow();
        await tester.pumpAndSettle();
        expect(find.textContaining('Question 39'), findsOneWidget);
        await _expectScrolls(tester);
      },
    );
  }
}
