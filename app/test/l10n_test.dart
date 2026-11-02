import 'dart:convert';
import 'dart:io';

import 'package:app/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every English string has a Chinese translation', () {
    Set<String> keys(String path) =>
        (jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>).keys
            .where((k) => !k.startsWith('@'))
            .toSet();
    expect(keys('lib/l10n/app_zh.arb'), keys('lib/l10n/app_en.arb'));
  });

  testWidgets('a Chinese device gets Chinese UI strings', (tester) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = context.l10n;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(l10n.settings, '设置');
    expect(l10n.ranCommands(3), '已运行 3 条命令');
    expect(l10n.versionReady('1.3.0', '80'), '版本 1.3.0（80）已可下载。');
  });

  testWidgets('without app localizations, widgets fall back to English', (
    tester,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            l10n = context.l10n;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(l10n.settings, 'Settings');
    expect(l10n.ranCommands(1), 'Ran a command');
  });
}
