// Accessibility checks on the main screens, in both themes: tap targets at
// least 48×48, every tappable thing labelled, and text contrast.

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
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../support/acp_harness.dart';

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

Future<void> _check(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(textContrastGuideline));
}

void main() {
  for (final dark in [false, true]) {
    final theme = dark ? buildDarkTheme() : buildLightTheme();
    final name = dark ? 'dark' : 'light';

    testWidgets('home, sidebar and chat are accessible ($name)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = Preferences();
      await prefs.load();
      final peer = testPeer(name: 'studio');
      final storage = MemoryStorage([peer]);
      final host =
          FakeHost(
              sessions: [
                testSession(
                  title: 'Fix the login redirect',
                  cwd: '/home/me/web',
                ),
                testSession(
                  id: 's2',
                  title: 'Write notes',
                  cwd: '/home/me/web',
                ),
              ],
            )
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
            ];
      final hosts = testHosts(storage, host);
      await hosts.start();
      await pumpOnline(tester, hosts);
      final home = HomeViewModel(hosts, storage, prefs);
      final common = <SingleChildWidget>[
        ChangeNotifierProvider<Preferences>.value(value: prefs),
        ChangeNotifierProvider<HomeViewModel>.value(value: home),
        ChangeNotifierProvider(create: (_) => SessionSelection()),
        ChangeNotifierProvider<Hosts>.value(value: hosts),
      ];

      Future<void> screen(
        Widget page, [
        List<SingleChildWidget> extra = const [],
      ]) async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [...common, ...extra],
            child: MaterialApp(theme: theme, home: page),
          ),
        );
        await tester.pumpAndSettle();
        await _check(tester);
      }

      await screen(const SessionShell(child: SessionWelcome()));
      await screen(const Scaffold(body: SafeArea(child: SessionSidebar())));
      await screen(const SettingsPage(), [
        ChangeNotifierProvider(
          create: (_) => SettingsViewModel(storage, prefs, hosts),
        ),
      ]);

      final session = SessionController(hosts.all.single, 's1');
      await screen(const ChatPage(), [
        ChangeNotifierProvider<SessionController>.value(value: session),
        ChangeNotifierProvider(create: (_) => VoiceInputViewModel(_Speech())),
        ChangeNotifierProvider(create: (_) => AttachmentViewModel(_Picker())),
      ]);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
      home.dispose();
      hosts.dispose();
      handle.dispose();
    });
  }
}
