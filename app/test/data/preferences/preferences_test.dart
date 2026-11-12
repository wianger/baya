import 'dart:convert';

import 'package:app/acp/acp.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/ui/core/themes/app_font_scale.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('Preferences', () {
    test('defaults to hideToolCalls=false before load()', () {
      final p = Preferences(_FakeSecureStorage());
      expect(p.hideToolCalls, isFalse);
    });

    test('load() hydrates from storage', () async {
      final store = _FakeSecureStorage();
      await store.write(key: 'prefs.hide_tool_calls', value: 'true');
      final p = Preferences(store);
      await p.load();
      expect(p.hideToolCalls, isTrue);
    });

    test('setHideToolCalls writes to storage and notifies', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      var notifs = 0;
      p.addListener(() => notifs++);

      await p.setHideToolCalls(true);
      expect(p.hideToolCalls, isTrue);
      expect(await store.read(key: 'prefs.hide_tool_calls'), 'true');
      expect(notifs, 1);

      // No-op if value unchanged.
      await p.setHideToolCalls(true);
      expect(notifs, 1);

      await p.setHideToolCalls(false);
      expect(p.hideToolCalls, isFalse);
      expect(notifs, 2);
    });

    test('tailnetDomain round-trips', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      expect(p.tailnetDomain, isNull);
      await p.setTailnetDomain('tail1234.ts.net');
      final p2 = Preferences(store);
      await p2.load();
      expect(p2.tailnetDomain, 'tail1234.ts.net');
    });

    test('onboardingCompleted defaults to false and round-trips via '
        'setOnboardingCompleted', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      expect(p.onboardingCompleted, isFalse);

      await p.setOnboardingCompleted(true);
      expect(p.onboardingCompleted, isTrue);
      expect(await store.read(key: 'prefs.onboarding_completed'), 'true');

      final p2 = Preferences(store);
      await p2.load();
      expect(p2.onboardingCompleted, isTrue);
    });

    // In-app text size.
    test(
      'fontScale defaults to standard and round-trips through storage',
      () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        await p.load();
        expect(p.fontScale, AppFontScale.standard);

        await p.setFontScale(AppFontScale.large);
        expect(p.fontScale, AppFontScale.large);

        final reloaded = Preferences(store);
        await reloaded.load();
        expect(reloaded.fontScale, AppFontScale.large);
      },
    );

    test('an unknown persisted font scale falls back to standard', () async {
      final store = _FakeSecureStorage();
      // A stale/corrupt value must never leave the app at an unreadable size.
      await store.write(key: 'prefs.font_scale', value: 'gigantic');
      final p = Preferences(store);
      await p.load();
      expect(p.fontScale, AppFontScale.standard);
    });

    test('setFontScale notifies listeners only on a real change', () async {
      final p = Preferences(_FakeSecureStorage());
      var calls = 0;
      p.addListener(() => calls++);

      await p.setFontScale(AppFontScale.small);
      expect(calls, 1);
      await p.setFontScale(AppFontScale.small);
      expect(calls, 1);
    });

    test(
      'deleteWorkspace clears its name, assignments and selection',
      () async {
        final store = _FakeSecureStorage();
        final p = Preferences(store);
        await p.load();
        final device = base64Encode(List.filled(32, 19));
        const session = 'session-alpha';
        final workspace = '$device:workspace:release';

        await p.setWorkspaceName(workspace, 'Release train');
        await p.setSessionWorkspace(device, session, workspace);
        await p.setSelectedWorkspace(workspace);
        expect(p.isCustomWorkspace(workspace), isTrue);
        expect(p.workspaceForSession(device, session), workspace);
        expect(p.workspaceForDevice(device), workspace);

        await p.deleteWorkspace(workspace);
        expect(p.isCustomWorkspace(workspace), isFalse);
        expect(p.workspaceForSession(device, session), isNull);
        expect(p.workspaceForDevice(device), isNull);

        final restored = Preferences(store);
        await restored.load();
        expect(restored.workspaceName(workspace), isNull);
        expect(restored.workspaceForSession(device, session), isNull);
        expect(restored.workspaceForDevice(device), isNull);
        restored.dispose();
      },
    );

    test('load discards folder-derived workspaces and assignments', () async {
      final store = _FakeSecureStorage();
      final device = base64Encode(List.filled(32, 23));
      await store.write(
        key: 'prefs.workspace_navigation',
        value: jsonEncode({
          'device': device,
          'workspaces': {device: '$device:/code/old'},
        }),
      );
      await store.write(
        key: 'prefs.session_workspaces',
        value: jsonEncode({'$device:session': '$device:/code/old'}),
      );
      await store.write(
        key: 'prefs.workspace_names',
        value: jsonEncode({'$device:/code/old': 'Old folder'}),
      );

      final p = Preferences(store);
      await p.load();

      expect(p.selectedDeviceEpk, device);
      expect(p.workspaceForDevice(device), isNull);
      expect(p.workspaceForSession(device, 'session'), isNull);
      expect(p.isCustomWorkspace('$device:/code/old'), isFalse);
      p.dispose();
    });

    test('rejects a workspace assigned across devices', () async {
      final p = Preferences(_FakeSecureStorage());
      await p.load();
      final first = base64Encode(List.filled(32, 24));
      final second = base64Encode(List.filled(32, 25));
      final foreign = workspaceKey(second, 'foreign');

      await expectLater(
        p.setSessionWorkspace(first, 'session', foreign),
        throwsArgumentError,
      );
      expect(p.workspaceForSession(first, 'session'), isNull);
      p.dispose();
    });

    test('Inbox is a permanent system workspace', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      await p.load();
      final device = base64Encode(List.filled(32, 26));
      final inbox = inboxWorkspaceKey(device);

      expect(p.canDeleteWorkspace(inbox), isFalse);
      expect(() => p.deleteWorkspace(inbox), throwsArgumentError);

      await p.setWorkspaceName(inbox, 'Inbox renamed');
      expect(p.workspaceName(inbox), 'Inbox renamed');
      expect(p.isCustomWorkspace(inbox), isFalse);
      expect(p.canDeleteWorkspace(inbox), isFalse);

      final restored = Preferences(store);
      await restored.load();
      expect(restored.workspaceName(inbox), 'Inbox renamed');
      expect(restored.isCustomWorkspace(inbox), isFalse);
      p.dispose();
      restored.dispose();
    });

    test('deleting a workspace returns its sessions to Inbox', () async {
      final p = Preferences(_FakeSecureStorage());
      await p.load();
      final device = base64Encode(List.filled(32, 27));
      final workspace = workspaceKey(device, 'release');
      await p.setWorkspaceName(workspace, 'Release');
      await p.setSessionWorkspace(device, 'session-a', workspace);
      await p.setSessionWorkspace(device, 'session-b', workspace);
      await p.setSelectedWorkspace(workspace);

      await p.deleteWorkspace(workspace);

      expect(p.isCustomWorkspace(workspace), isFalse);
      expect(p.workspaceForSession(device, 'session-a'), isNull);
      expect(p.workspaceForSession(device, 'session-b'), isNull);
      expect(
        p.workspaceForDevice(device) ?? inboxWorkspaceKey(device),
        inboxWorkspaceKey(device),
      );
      p.dispose();
    });

    test('a session is unread once the agent did something not seen', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      await p.load();
      final now = DateTime.now();
      SessionSummary session(DateTime at, {bool working = false}) =>
          SessionSummary(
            sessionId: 's1',
            cwd: '/w',
            title: 'Fix login',
            agent: 'claude',
            agentName: 'Claude Code',
            updatedAt: at,
            working: working,
          );
      const host = 'AAAA';

      // What happened before the phone kept track is not new.
      expect(
        p.isUnread(host, session(now.subtract(const Duration(days: 1)))),
        isFalse,
      );
      final later = now.add(const Duration(minutes: 5));
      expect(p.isUnread(host, session(later)), isTrue);
      // Still working: the spinner says so, not the dot.
      expect(p.isUnread(host, session(later, working: true)), isFalse);

      p.markSeen(host, session(later));
      expect(p.isUnread(host, session(later)), isFalse);
      final again = later.add(const Duration(minutes: 1));
      expect(p.isUnread(host, session(again)), isTrue);

      // Kept across launches.
      final reloaded = Preferences(store);
      await reloaded.load();
      expect(reloaded.isUnread(host, session(later)), isFalse);
      expect(reloaded.isUnread(host, session(again)), isTrue);
      p.dispose();
      reloaded.dispose();
    });

    test('messages sent again and again become quick replies', () async {
      final store = _FakeSecureStorage();
      final p = Preferences(store);
      await p.load();
      final day = DateTime(2026, 11, 2);
      for (var i = 0; i < 3; i++) {
        p.rememberSent('run the tests', now: day);
      }
      p
        ..rememberSent('ship it', now: day)
        ..rememberSent('ship it', now: day)
        ..rememberSent('once', now: day)
        ..rememberSent('/compact', now: day)
        ..rememberSent('two\nlines', now: day)
        ..rememberSent('ship it', now: day);
      expect(p.phrases(now: day), ['run the tests', 'ship it']);

      // Unsent for weeks, a phrase fades behind one in use.
      final later = day.add(const Duration(days: 30));
      p
        ..rememberSent('lgtm', now: later)
        ..rememberSent('lgtm', now: later);
      expect(p.phrases(now: later).first, 'lgtm');

      final reloaded = Preferences(store);
      await reloaded.load();
      expect(reloaded.phrases(now: later), p.phrases(now: later));
      p.dispose();
      reloaded.dispose();
    });
  });
}
