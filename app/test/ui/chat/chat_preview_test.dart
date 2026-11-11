import 'dart:async';
// Renders the chat screen with a sample ACP conversation to PNG for design
// review: `BAYA_PREVIEW_DIR=<dir> flutter test test/ui/chat/chat_preview_test.dart`.
// Skipped otherwise.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/data/hosts/session_controller.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/session_settings_sheet.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/acp_harness.dart';
import '../../support/fonts.dart';

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

Map<String, dynamic> _text(String kind, String text, [String? id]) => {
  'sessionUpdate': kind,
  'content': {'type': 'text', 'text': text},
  'messageId': ?id,
};

FakeHost _computer() =>
    FakeHost(
        sessions: [testSession(title: 'Fix the login redirect', working: true)],
      )
      ..history['s1'] = [
        _text(
          'user_message_chunk',
          'Login sends me back to /login after signing in. Fix it.',
          'm1',
        ),
        _text(
          'agent_thought_chunk',
          'The redirect probably reads the cookie before it is set.',
        ),
        {
          'sessionUpdate': 'plan',
          'entries': [
            {
              'content': 'Find where the redirect happens',
              'priority': 'high',
              'status': 'completed',
            },
            {
              'content': 'Wait for the session cookie',
              'priority': 'high',
              'status': 'in_progress',
            },
            {
              'content': 'Run the auth tests',
              'priority': 'medium',
              'status': 'pending',
            },
          ],
        },
        {
          'sessionUpdate': 'tool_call',
          'toolCallId': 't1',
          'title': 'grep -rn "redirect" src/auth',
          'kind': 'search',
          'status': 'completed',
          'rawInput': {
            'pattern': 'redirect',
            'path': 'src/auth',
            'glob': '*.ts',
          },
          'content': [
            {
              'type': 'content',
              'content': {
                'type': 'text',
                'text': 'src/auth/login.ts:42: router.push(next)',
              },
            },
          ],
        },
        {
          'sessionUpdate': 'tool_call',
          'toolCallId': 't2',
          'title': 'Edit src/auth/login.ts',
          'kind': 'edit',
          'status': 'completed',
          'locations': [
            {'path': 'src/auth/login.ts', 'line': 42},
          ],
          'content': [
            {
              'type': 'diff',
              'path': 'src/auth/login.ts',
              'oldText': 'await signIn(form)\nrouter.push(next)',
              'newText': 'await signIn(form)\nawait session.ready()\nrouter.push(next)',
            },
          ],
        },
        {
          'sessionUpdate': 'tool_call',
          'toolCallId': 't4',
          'title': 'Read src/auth/session.ts',
          'kind': 'read',
          'status': 'completed',
          'locations': [
            {'path': 'src/auth/session.ts'},
          ],
        },
        {
          'sessionUpdate': 'tool_call',
          'toolCallId': 't5',
          'title': 'npm run typecheck',
          'kind': 'execute',
          'status': 'completed',
          'rawInput': {'command': 'npm run typecheck'},
          'content': [
            {
              'type': 'content',
              'content': {
                'type': 'text',
                'text': '> tsc --noEmit\n\nFound 0 errors. Watching for file changes.',
              },
            },
          ],
        },
        _text(
          'agent_message_chunk',
          'The redirect ran before the session cookie existed. It now **waits for `session.ready()`** first.',
        ),
        {
          'sessionUpdate': 'tool_call',
          'toolCallId': 't3',
          'title': 'npm test -- auth',
          'kind': 'execute',
          'status': 'pending',
          'rawInput': {'command': 'npm test -- auth'},
        },
        {'sessionUpdate': 'usage_update', 'used': 74240, 'size': 200000},
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
              {'value': 'opus', 'name': 'Opus 4.7'},
              {'value': 'sonnet', 'name': 'Sonnet 4.6'},
            ],
          },
          {
            'id': 'effort',
            'name': 'Reasoning effort',
            'category': 'thought_level',
            'type': 'select',
            'currentValue': 'high',
            'options': [
              {'value': 'low', 'name': 'Low'},
              {'value': 'high', 'name': 'High'},
            ],
          },
        ],
        'modes': {
          'currentModeId': 'default',
          'availableModes': [
            {'id': 'default', 'name': 'Ask before edits'},
            {'id': 'acceptEdits', 'name': 'Accept edits'},
          ],
        },
        '_meta': {
          'baya': {
            'agentName': 'Claude Code',
            'working': true,
            'promptCapabilities': {'image': true},
          },
        },
      };

Future<void> _fonts(WidgetTester tester) async {
  await loadAppFonts(tester);
  await tester.runAsync(() async {
    final fallback = File(r'C:\Windows\Fonts\segoeui.ttf');
    if (fallback.existsSync()) {
      await (FontLoader(
        'Roboto',
      )..addFont(fallback.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
}

Future<void> _save(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  final output = Platform.environment['BAYA_PREVIEW_DIR'];
  testWidgets('chat preview', (tester) async {
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _fonts(tester);
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();
    final host = _computer();
    final hosts = testHosts(
      MemoryStorage([testPeer(name: 'studio (WSL)')]),
      host,
    );
    await hosts.start();
    await pumpOnline(tester, hosts);
    final session = SessionController(hosts.all.single, 's1');
    final boundary = GlobalKey();
    final light = Platform.environment['BAYA_PREVIEW_THEME'] == 'light';
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: (light ? buildLightTheme() : buildDarkTheme()).copyWith(
            platform: TargetPlatform.android,
          ),
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<SessionController>.value(value: session),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider(create: (_) => SessionSelection()),
              ChangeNotifierProvider(
                create: (_) => VoiceInputViewModel(_Speech()),
              ),
              ChangeNotifierProvider(
                create: (_) => AttachmentViewModel(_Picker()),
              ),
            ],
            child: const ChatPage(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    host.askPermission({
      'sessionId': 's1',
      'toolCall': {'toolCallId': 't3'},
      'options': [
        {'optionId': 'once', 'name': 'Allow', 'kind': 'allow_once'},
        {'optionId': 'always', 'name': 'Always allow', 'kind': 'allow_always'},
        {'optionId': 'no', 'name': 'Reject', 'kind': 'reject_once'},
      ],
    }).ignore();
    await tester.pump(const Duration(seconds: 1));
    await _save(tester, boundary, '$output/chat.png');

    await tester.tap(find.byKey(const Key('tool-run-group')));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('tool-details-t5')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // ignore: avoid_print
    print(
      'DBG cmd=${find.byKey(const Key('tool-command')).evaluate().length} changes=${find.byKey(const Key('tool-changes')).evaluate().length} ex=${tester.takeException()}',
    );
    await tester.pump(const Duration(seconds: 1));
    await _save(tester, boundary, '$output/tools-open.png');
    await tester.tap(find.byKey(const ValueKey('tool-details-t5')));
    await tester.tap(find.byKey(const ValueKey('tool-details-t2')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _save(tester, boundary, '$output/diff-open.png');

    await tester.tap(find.byKey(const Key('chat-actions')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _save(tester, boundary, '$output/session-sheet.png');
    await tester.tap(find.byKey(const ValueKey('session-action-delete')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _save(tester, boundary, '$output/session-delete.png');
    Navigator.of(tester.element(find.byKey(const Key('session-sheet')))).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final context = tester.element(find.byType(ChatPage));
    unawaited(showContextUsage(context));
    // The first frame starts the sheet's animation; the second finishes it.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // ignore: avoid_print
    print(
      'sheet: ${find.byKey(const Key('context-sheet')).evaluate().length} ${tester.takeException()}',
    );
    await _save(tester, boundary, '$output/context.png');
    Navigator.of(context).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    unawaited(showSessionSettings(context));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _save(tester, boundary, '$output/settings.png');

    await tester.pumpWidget(const SizedBox());
    session.dispose();
    hosts.dispose();
    prefs.dispose();
  }, skip: output == null);
}
