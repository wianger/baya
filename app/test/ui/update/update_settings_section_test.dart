import 'dart:async';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:app/ui/update/widgets/update_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Checker implements UpdateChecker {
  final response = Completer<UpdateInfo?>();
  @override
  Future<UpdateInfo?> fetchLatest() => response.future;
}

class _Store implements DismissedUpdateStore {
  @override
  Future<String?> dismissedVersion() async => null;
  @override
  Future<void> dismiss(String version) async {}
}

class _Opener implements UrlOpener {
  final urls = <String>[];
  @override
  Future<bool> open(String url) async {
    urls.add(url);
    return true;
  }
}

void main() {
  testWidgets(
    'settings check shows progress, release notes and the APK download action',
    (tester) async {
      final checker = _Checker(), opener = _Opener();
      final vm = UpdateBannerViewModel(
        checker,
        _Store(),
        opener,
        currentVersion: '1.2.1',
        currentBuildNumber: 9,
        enabled: true,
      );
      addTearDown(vm.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: vm,
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(child: UpdateSettingsSection()),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('check-github-updates')));
      await tester.pump();
      expect(find.text('Checking GitHub…'), findsOneWidget);
      const url =
          'https://github.com/wianger/baya/releases/download/android-dev-v1.2.2+10/Baya-Android.apk';
      checker.response.complete(
        const UpdateInfo(
          version: '1.2.2',
          buildNumber: 10,
          date: '',
          notes: 'Fix resumed conversations',
          artifacts: [
            UpdateArtifact(
              platform: 'android',
              arch: 'arm64',
              format: 'apk',
              url: url,
              sha256: '',
              size: 42,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fix resumed conversations'), findsOneWidget);
      // A newer build was found: _check now shows a BayaNotice confirm modal.
      expect(find.byKey(const Key('baya-notice')), findsOneWidget);
      // The inline card also renders below the modal.
      expect(find.text('Fix resumed conversations'), findsOneWidget);
      // Tap the modal's confirm button, which calls _download() → opener.
      await tester.tap(find.byKey(const Key('baya-notice-confirm')));
      await tester.pump();
      expect(opener.urls, [url]);
    },
  );
}
