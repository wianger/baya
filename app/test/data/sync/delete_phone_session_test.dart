import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import '../../support/phone_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('rp_phone_delete_');
    await LocalBoxes.initForTest(dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    if (!dir.absolute.path.startsWith(
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}',
    )) {
      throw StateError('Unsafe cleanup path');
    }
    await dir.delete(recursive: true);
  });
  test('phone deletion clears cache, survives relaunch and rejects late history without stopping the PC', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = Preferences();
    await prefs.load();
    final peer = phoneTestPeer();
    final channel = PhoneTestChannel(), storage = PhoneTestStorage([peer]);
    final conn = ConnectionManager(
      storage: storage,
      factory: (_, _) async => channel,
      emitDebounce: Duration.zero,
    );
    conn.adopt(channel, peer);
    final boxes = LocalBoxes();
    final sync = SyncService(
      conn,
      boxes,
      isSessionHidden: prefs.isSessionHidden,
    );
    final home = HomeViewModel(storage, prefs, conn, sync);
    await sync.activate(peer.remoteEpk, peer.roomId!);
    channel.control.add(
      RoomAnnounced(
        peer: peer.remoteEpk,
        room: RoomInfo(
          roomId: peer.roomId!,
          name: 'Task',
          cwd: '/code/project',
          startedAt: 1,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await sync.sendMessage('cached conversation');
    final box = await boxes.msgsBox(peer.remoteEpk, peer.roomId!);
    expect(box.isNotEmpty, isTrue);
    final sentBeforeDelete = channel.sent.length;
    final deletedSession = home.allItems.single;
    await home.deleteSession(deletedSession);
    final workspace = inboxWorkspaceKey(peer.remoteEpk);
    expect(box.isEmpty, isTrue);
    expect(home.allItems, isEmpty);
    expect(home.workspaces[workspace], 'No sessions yet');
    channel.messages.add(
      AgentMessage(
        inReplyTo: 'late',
        text: 'late output must not recreate cache',
      ),
    );
    channel.control.add(
      RoomAnnounced(
        peer: peer.remoteEpk,
        room: RoomInfo(
          roomId: peer.roomId!,
          name: 'Task',
          cwd: '/code/project',
          startedAt: 1,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(box.isEmpty, isTrue);
    expect(home.allItems, isEmpty);
    expect(
      channel.sent.length,
      sentBeforeDelete,
      reason: 'No stop/delete command is sent to the computer',
    );
    final restoredPrefs = Preferences();
    await restoredPrefs.load();
    expect(restoredPrefs.isSessionHidden(peer.remoteEpk, peer.roomId!), isTrue);
    expect(restoredPrefs.isCustomWorkspace(workspace), isFalse);
    final homeAfterRestart = HomeViewModel(storage, restoredPrefs, conn);
    final syncAfterRestart = SyncService(
      conn,
      boxes,
      isSessionHidden: restoredPrefs.isSessionHidden,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(homeAfterRestart.allItems, isEmpty);
    expect(homeAfterRestart.workspaces[workspace], 'No sessions yet');
    expect(box.isEmpty, isTrue);
    await restoredPrefs.restoreSession(peer.remoteEpk, peer.roomId!);
    expect(
      homeAfterRestart.allItems,
      hasLength(1),
      reason: 'An explicit reopen may restore the phone view',
    );
    homeAfterRestart.dispose();
    syncAfterRestart.dispose();
    restoredPrefs.dispose();
    home.dispose();
    sync.dispose();
    conn.dispose();
    prefs.dispose();
    await channel.disposeStreams();
  });
}
