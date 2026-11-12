import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/update_prompt.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Hand-written fakes (no mocktail in this repo) ──────────────────────────

class _FakeChecker implements UpdateChecker {
  _FakeChecker(this.result);
  UpdateInfo? result;
  int calls = 0;
  @override
  Future<UpdateInfo?> fetchLatest() async {
    calls++;
    return result;
  }
}

class _FakeDismissedStore implements DismissedUpdateStore {
  _FakeDismissedStore([this._version]);
  String? _version;
  final List<String> dismissedCalls = [];
  @override
  Future<String?> dismissedVersion() async => _version;
  @override
  Future<void> dismiss(String version) async {
    dismissedCalls.add(version);
    _version = version;
  }
}

class _FakeOpener implements UrlOpener {
  final List<String> opened = [];
  bool result = true;
  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return result;
  }
}

UpdateInfo _info(String version, {List<UpdateArtifact>? artifacts}) =>
    UpdateInfo(
      version: version,
      date: '2026-06-12',
      notes: '',
      artifacts:
          artifacts ??
          const [
            UpdateArtifact(
              platform: 'android',
              arch: 'universal',
              format: 'apk',
              url: 'https://example.com/RemotePi.apk',
              sha256: '',
              size: 0,
            ),
          ],
    );

UpdateBannerViewModel _vm(
  _FakeChecker checker, {
  bool enabled = true,
  String current = '1.1.0',
  _FakeDismissedStore? store,
  _FakeOpener? opener,
}) => UpdateBannerViewModel(
  checker,
  store ?? _FakeDismissedStore(),
  opener ?? _FakeOpener(),
  currentVersion: current,
  enabled: enabled,
);

void main() {
  group('on opening the app', () {
    test('checks again only once the given while has passed', () async {
      final checker = _FakeChecker(null);
      final vm = _vm(checker);
      final t0 = DateTime(2026, 11, 5, 9);
      await vm.check(now: t0);
      await vm.check(
        after: const Duration(hours: 6),
        now: t0.add(const Duration(hours: 2)),
      );
      expect(checker.calls, 1);
      await vm.check(
        after: const Duration(hours: 6),
        now: t0.add(const Duration(hours: 7)),
      );
      expect(checker.calls, 2);
      // Plain check() stays once.
      await vm.check(now: t0.add(const Duration(days: 2)));
      expect(checker.calls, 2);
    });

    testWidgets('the prompt shows the release; Later hides this version', (
      tester,
    ) async {
      final store = _FakeDismissedStore();
      final opener = _FakeOpener();
      final vm = _vm(
        _FakeChecker(
          const UpdateInfo(
            version: '2.15.0',
            buildNumber: 113,
            date: '2026-11-05',
            notes: 'Files open on the phone.',
            artifacts: [],
          ),
        ),
        store: store,
        opener: opener,
      );
      await tester.runAsync(vm.check);
      final info = (vm.state as UpdateBannerVisible).info;
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const Scaffold();
            },
          ),
        ),
      );
      showUpdatePrompt(context, vm, info).ignore();
      await tester.pumpAndSettle();
      expect(find.text('Baya 2.15.0 is out'), findsOneWidget);
      expect(find.text('Files open on the phone.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('update-later')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-prompt')), findsNothing);
      expect(store.dismissedCalls, ['2.15.0']);

      // Download opens the release when asked.
      final again = _vm(
        _FakeChecker(info),
        opener: opener,
        store: _FakeDismissedStore(),
      );
      await tester.runAsync(again.check);
      showUpdatePrompt(context, again, info).ignore();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('update-download')));
      await tester.pumpAndSettle();
      expect(opener.opened, hasLength(1));
    });
  });

  group('UpdateBannerViewModel.check — gating', () {
    test('newer + not dismissed → Visible', () async {
      final vm = _vm(_FakeChecker(_info('1.2.0')));
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());
      expect((vm.state as UpdateBannerVisible).info.version, '1.2.0');
    });

    test('disabled (iOS) → never fetches, stays Hidden', () async {
      final checker = _FakeChecker(_info('9.9.9'));
      final vm = _vm(checker, enabled: false);
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
      expect(checker.calls, 0, reason: 'iOS gate short-circuits before fetch');
    });

    test('manifest unavailable (null) → Hidden', () async {
      final vm = _vm(_FakeChecker(null));
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('equal version → Hidden', () async {
      final vm = _vm(_FakeChecker(_info('1.1.0')));
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('lower version → Hidden', () async {
      final vm = _vm(_FakeChecker(_info('1.0.0')));
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('already dismissed this version → Hidden', () async {
      final vm = _vm(
        _FakeChecker(_info('1.2.0')),
        store: _FakeDismissedStore('1.2.0'),
      );
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test(
      'dismissed an OLDER version → still Visible for the newer one',
      () async {
        final vm = _vm(
          _FakeChecker(_info('1.3.0')),
          store: _FakeDismissedStore('1.2.0'),
        );
        await vm.check();
        expect(vm.state, isA<UpdateBannerVisible>());
      },
    );

    test('check is idempotent per instance (single fetch)', () async {
      final checker = _FakeChecker(_info('1.2.0'));
      final vm = _vm(checker);
      await vm.check();
      await vm.check();
      expect(checker.calls, 1);
    });
  });

  group('UpdateBannerViewModel.dismiss', () {
    test('hides the card and persists the version', () async {
      final store = _FakeDismissedStore();
      final vm = _vm(_FakeChecker(_info('1.2.0')), store: store);
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());

      await vm.dismiss();
      expect(vm.state, isA<UpdateBannerHidden>());
      expect(store.dismissedCalls, ['1.2.0']);
    });

    test('no-op when nothing is visible', () async {
      final store = _FakeDismissedStore();
      final vm = _vm(_FakeChecker(null), store: store);
      await vm.check();
      await vm.dismiss();
      expect(store.dismissedCalls, isEmpty);
    });
  });

  group('manual development update check', () {
    test(
      'build code detects a newer rebuild with the same visible version',
      () async {
        final info = const UpdateInfo(
          version: '1.2.1',
          date: '',
          notes: '',
          artifacts: [],
          buildNumber: 10,
        );
        final checker = _FakeChecker(info);
        final vm = UpdateBannerViewModel(
          checker,
          _FakeDismissedStore('1.2.1'),
          _FakeOpener(),
          currentVersion: '1.2.1',
          currentBuildNumber: 9,
          enabled: true,
        );
        await vm.checkManually();
        expect(vm.state, isA<UpdateBannerVisible>());
        checker.result = const UpdateInfo(
          version: '1.2.1',
          date: '',
          notes: '',
          artifacts: [],
          buildNumber: 9,
        );
        await vm.checkManually();
        expect(vm.state, isA<UpdateCheckCurrent>());
      },
    );
    test(
      'manual check bypasses dismissal and permits retry after API failure',
      () async {
        final checker = _FakeChecker(null);
        final vm = _vm(checker, store: _FakeDismissedStore('1.2.0'));
        await vm.checkManually();
        expect(vm.state, isA<UpdateCheckFailed>());
        checker.result = _info('1.2.0');
        await vm.checkManually();
        expect(vm.state, isA<UpdateBannerVisible>());
        expect(checker.calls, 2);
      },
    );
    test(
      'a newer version with an older Android build code is not installable',
      () async {
        final vm = UpdateBannerViewModel(
          _FakeChecker(
            const UpdateInfo(
              version: '2.0.0',
              date: '',
              notes: '',
              artifacts: [],
              buildNumber: 8,
            ),
          ),
          _FakeDismissedStore(),
          _FakeOpener(),
          currentVersion: '1.2.1',
          currentBuildNumber: 9,
          enabled: true,
        );
        await vm.checkManually();
        expect(vm.state, isA<UpdateCheckCurrent>());
      },
    );
  });

  group('UpdateBannerViewModel.download', () {
    test('opens the android/apk artifact url', () async {
      final opener = _FakeOpener();
      final vm = _vm(_FakeChecker(_info('1.2.0')), opener: opener);
      await vm.check();
      await vm.download();
      expect(opener.opened, ['https://example.com/RemotePi.apk']);
    });

    test('falls back to the download page when no apk artifact', () async {
      final opener = _FakeOpener();
      final info = _info(
        '1.2.0',
        artifacts: const [
          UpdateArtifact(
            platform: 'macos',
            arch: 'universal',
            format: 'dmg',
            url: 'https://example.com/RemotePi.dmg',
            sha256: '',
            size: 0,
          ),
        ],
      );
      final vm = _vm(_FakeChecker(info), opener: opener);
      await vm.check();
      await vm.download();
      expect(opener.opened, ['https://github.com/wianger/baya/releases']);
    });
  });
}
