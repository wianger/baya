import 'package:app/data/hosts/session_controller.dart';
import 'package:app/ui/changes/changes_page.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

void main() {
  testWidgets('reviews a file, reverts one hunk, then commits', (tester) async {
    var files = <Map<String, dynamic>>[
      {'path': 'src/a.ts', 'status': 'M', 'added': 2, 'removed': 1},
    ];
    var hunks = <Map<String, dynamic>>[
      {
        'header': '@@ -1,2 +1,2 @@',
        'oldStart': 1,
        'newStart': 1,
        'lines': [
          {'kind': '-', 'text': 'const a = 1;'},
          {'kind': '+', 'text': 'const a = 2;'},
        ],
      },
      {
        'header': '@@ -9,1 +9,2 @@',
        'oldStart': 9,
        'newStart': 9,
        'lines': [
          {'kind': ' ', 'text': 'export {};'},
          {'kind': '+', 'text': 'log(a);'},
        ],
      },
    ];
    final host = FakeHost(sessions: [testSession()]);
    host.handlers['_baya/git_status'] = (_) => {
      'branch': 'main',
      'upstream': 'origin/main',
      'ahead': 0,
      'behind': 0,
      'files': files,
    };
    host.handlers['_baya/git_diff'] = (_) => {
      'path': 'src/a.ts',
      'hunks': hunks,
    };
    host.handlers['_baya/git_revert'] = (params) {
      hunks = [hunks[1]];
      return {'path': 'src/a.ts', 'hunks': hunks};
    };
    host.handlers['_baya/git_commit'] = (_) {
      files = [];
      return {'commit': 'abc1234'};
    };
    final hosts = testHosts(MemoryStorage([testPeer()]), host);
    await hosts.start();
    await pumpOnline(tester, hosts);
    final session = SessionController(hosts.all.single, 's1');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: ChangesPage(session: session),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('a.ts'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('change-src/a.ts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('hunk-1')), findsOneWidget);
    // Reverting takes two taps.
    await tester.tap(find.byKey(const ValueKey('revert-hunk-0')));
    await tester.pump();
    expect(host.calls.where((c) => c.method == '_baya/git_revert'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('revert-hunk-0')));
    await tester.pumpAndSettle();
    final revert = host.calls.lastWhere((c) => c.method == '_baya/git_revert');
    expect(revert.params, containsPair('hunk', 0));
    expect(find.byKey(const ValueKey('hunk-1')), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('commit-message')), 'Fix a');
    await tester.pump();
    await tester.tap(find.byKey(const Key('commit')));
    await tester.pumpAndSettle();
    final commit = host.calls.lastWhere((c) => c.method == '_baya/git_commit');
    expect(commit.params['message'], 'Fix a');
    expect(find.text('No changes'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
    hosts.dispose();
  });
}
