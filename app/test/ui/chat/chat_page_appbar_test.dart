// Plan/32g — the Chat AppBar's line 2 (paired-device name) must render from the
// `initialDevice` hint Home passes, immediately, WITHOUT waiting for the async
// PeerRecord. With no peer bound (activePeer == null), the device label still
// shows — proving the subtitle no longer depends on the async load (no flicker).

import 'dart:async';
import 'dart:io';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/domain/contracts/agent_commands_repository.dart';
import 'package:app/domain/contracts/context_usage_repository.dart';
import 'package:app/domain/entities/agent_command.dart';
import 'package:app/domain/entities/context_usage.dart';
import 'package:app/ui/chat/context/viewmodels/context_usage_viewmodel.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/commands/viewmodels/agent_commands_viewmodel.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';

class _FakeChannel implements IChannel {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  Future<void> close() => _ctrl.close();
}

/// No peer paired → ChatViewModel stays with activePeer == null (the case we
/// want: the subtitle must come from initialDevice, not the PeerRecord).
class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
  @override
  Future<PeerRecord?> loadPeer(String epk) async => null;
}

class _FakeSecureStorage implements FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeSpeech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakePicker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _ContextRepository implements IContextUsageRepository {
  @override
  Future<ContextUsageSnapshot> fetch() async => const ContextUsageSnapshot();
}

class _EmptyCommandsRepository implements IAgentCommandsRepository {
  @override
  Future<List<AgentCommand>> list() async => const [];

  @override
  void dispose() {}
}

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('rp_v2_chatpage_');
    await LocalBoxes.initForTest(dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets(
    'AppBar line 2 shows the device from initialDevice immediately — no '
    'PeerRecord needed (plan/32g)',
    (tester) async {
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage()); // no selected peer
      final actions = ActionsRepository(conn);
      final vm = ChatViewModel(read, sync, conn, prefs, _FakeStorage());
      final voice = VoiceInputViewModel(_FakeSpeech());
      final attach = AttachmentViewModel(_FakePicker(), actions);
      final sel = SessionSelection();
      final usage = ContextUsageViewModel(_ContextRepository());

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: vm),
              ChangeNotifierProvider<ContextUsageViewModel>.value(value: usage),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
              ChangeNotifierProvider<Preferences>.value(value: prefs),
              ChangeNotifierProvider<SessionSelection>.value(value: sel),
              ChangeNotifierProvider(
                create: (_) =>
                    AgentCommandsViewModel(_EmptyCommandsRepository()),
              ),
            ],
            child: const ChatPage(
              initialTitle: 'My Project',
              initialDevice: 'MacBook de Jacob',
              initialOnline: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // Line 2 = device (from initialDevice, even with no PeerRecord loaded).
      expect(find.text('MacBook de Jacob'), findsOneWidget);
      // Line 1 = room title (from initialTitle) — distinct from the device, so
      // we know the subtitle isn't just echoing the title fallback.
      expect(find.text('My Project'), findsOneWidget);

      // The info button renders immediately — even with no PeerRecord loaded
      // (activePeer == null here) — so it never pops in and shifts the AppBar.
      expect(find.byTooltip('Session actions'), findsOneWidget);

      // Status dot uses initialOnline before the runtime resolves → shows
      // "Ready" immediately instead of flashing offline/reconnecting.
      expect(find.text('Ready'), findsOneWidget);

      // Header and composer are independent overlays over the transcript,
      // rather than two rows that can be mistaken for floating controls.
      expect(find.byKey(const Key('chat-floating-header')), findsOneWidget);
      expect(find.byKey(const Key('chat-floating-composer')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const Key('chat-floating-header'))).bottom,
        lessThan(
          tester.getRect(find.byKey(const Key('chat-floating-composer'))).top,
        ),
      );

      final actionTrigger = find.byTooltip('Session actions');
      final actionTriggerRect = tester.getRect(actionTrigger);
      await tester.tap(actionTrigger);
      await tester.pump();
      final openingPopover = find.byKey(const Key('session-actions-popover'));
      expect(openingPopover, findsOneWidget);
      final openingRect = tester.getRect(openingPopover);
      expect(openingRect.right, closeTo(actionTriggerRect.right, 1));
      expect(openingRect.width, lessThan(actionTriggerRect.width + 2));
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester
            .widget<Transform>(
              find.byKey(const Key('baya-surface-content-scale')),
            )
            .transform
            .getMaxScaleOnAxis(),
        greaterThan(1),
      );
      await tester.pumpAndSettle();
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      // The action list replaces the upper-right controls while it opens.
      final popover = find.byKey(const Key('session-actions-popover'));
      expect(popover, findsOneWidget);
      final popoverRect = tester.getRect(popover);
      final headerRect = tester.getRect(
        find.byKey(const Key('chat-floating-header')),
      );
      final screenWidth =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(popoverRect.overlaps(headerRect), isTrue);
      expect(popoverRect.top, lessThan(actionTriggerRect.bottom));
      expect(popoverRect.right, closeTo(screenWidth - 12, 0.5));
      expect(popoverRect.center.dy, lessThan(screenHeight * .5));

      // Unmount + dispose in-body (the framework's pending-timer check runs
      // before addTearDown; conn's watchdog must be cancelled here).
      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      usage.dispose();
      attach.dispose();
      voice.dispose();
      actions.dispose();
      sync.dispose();
      sel.dispose();
      conn.dispose();
    },
  );

  testWidgets(
    'status line stays inside the header at narrow width with XL text scaling',
    (tester) async {
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      final actions = ActionsRepository(conn);
      final vm = ChatViewModel(read, sync, conn, prefs, _FakeStorage());
      final voice = VoiceInputViewModel(_FakeSpeech());
      final attach = AttachmentViewModel(_FakePicker(), actions);
      final sel = SessionSelection();
      final usage = ContextUsageViewModel(_ContextRepository());

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: MaterialApp(
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<ChatViewModel>.value(value: vm),
                ChangeNotifierProvider<ContextUsageViewModel>.value(
                  value: usage,
                ),
                ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
                ChangeNotifierProvider<AttachmentViewModel>.value(
                  value: attach,
                ),
                ChangeNotifierProvider<Preferences>.value(value: prefs),
                ChangeNotifierProvider<SessionSelection>.value(value: sel),
                ChangeNotifierProvider(
                  create: (_) =>
                      AgentCommandsViewModel(_EmptyCommandsRepository()),
                ),
              ],
              child: const Scaffold(
                body: SizedBox(
                  width: 320,
                  child: ChatPage(
                    initialTitle: 'My Project',
                    initialDevice: 'MacBook de Jacob',
                    initialOnline: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 320dp window + 1.3 font scale leaves too little room for an
      // unconstrained status label next to the device name and context ring.
      expect(tester.takeException(), isNull);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('MacBook de Jacob'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      usage.dispose();
      attach.dispose();
      voice.dispose();
      actions.dispose();
      sync.dispose();
      sel.dispose();
      conn.dispose();
    },
  );
}
