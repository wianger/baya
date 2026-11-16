import 'package:app/acp/acp.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/workspaces/computer_sessions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 11, 16, 12);

class _Repository implements IWorkspaceRepository {
  final opened = <(String, String, String, String?)>[];

  @override
  Future<ComputerSessions> computerSessions(String hostId) async =>
      ComputerSessions(
        [
          AgentSessionInfo(
            'c1',
            'Fix the login redirect',
            _now.subtract(const Duration(minutes: 1)),
            '/home/me/shop',
            'claude',
            'Claude Code',
          ),
          AgentSessionInfo(
            'x1',
            'Add an RSS index',
            _now.subtract(const Duration(hours: 3)),
            '/home/me/rss',
            'codex',
            'Codex',
          ),
          AgentSessionInfo(
            'x2',
            '',
            _now.subtract(const Duration(days: 2)),
            '/home/me/shop',
            'codex',
            'Codex',
          ),
        ],
        failed: const ['DeepSeek'],
      );

  @override
  Future<OpenedWorkspace> open(
    String hostId,
    String path,
    WorkspaceAgent agent, {
    String? agentSessionId,
    String? title,
  }) async {
    opened.add((path, agent.id, agentSessionId!, title));
    return OpenedWorkspace(
      hostId: hostId,
      hostLabel: 'PC',
      path: path,
      sessionId: 'baya-1',
      name: title ?? 'shop',
      agent: agent,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<_Repository> pump(WidgetTester tester, List<Object?> popped) async {
    final repository = _Repository();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => popped.add(
              await Navigator.of(context).push<Object>(
                MaterialPageRoute(
                  builder: (_) => ComputerSessionsPage(
                    launch: const ComputerSessionsLaunch(
                      hostId: 'host',
                      label: 'PC',
                    ),
                    repository: repository,
                    now: () => _now,
                  ),
                ),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('lists every agent, filters by agent and by text', (
    tester,
  ) async {
    await pump(tester, []);
    expect(find.text('Fix the login redirect'), findsOneWidget);
    expect(find.text('Add an RSS index'), findsOneWidget);
    expect(find.text('Untitled'), findsOneWidget);
    expect(find.textContaining('DeepSeek'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('computer-sessions-agent-codex')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fix the login redirect'), findsNothing);
    expect(find.text('Add an RSS index'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('computer-sessions-search')),
      'shop',
    );
    await tester.pumpAndSettle();
    expect(find.text('Add an RSS index'), findsNothing);
    expect(find.text('Untitled'), findsOneWidget);
  });

  testWidgets('continuing one opens it in its folder, with its title', (
    tester,
  ) async {
    final popped = <Object?>[];
    final repository = await pump(tester, popped);
    await tester.tap(find.text('Add an RSS index'));
    await tester.pumpAndSettle();
    expect(repository.opened, [
      ('/home/me/rss', 'codex', 'x1', 'Add an RSS index'),
    ]);
    expect(popped.single, isA<OpenedWorkspace>());
  });

  testWidgets('one written to minutes ago asks before continuing', (
    tester,
  ) async {
    final repository = await pump(tester, []);
    expect(find.byKey(const Key('computer-session-active')), findsOneWidget);
    await tester.tap(find.text('Fix the login redirect'));
    await tester.pumpAndSettle();
    expect(find.text('Still open somewhere?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.opened, isEmpty);

    await tester.tap(find.text('Fix the login redirect'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('computer-session-continue-anyway')));
    await tester.pumpAndSettle();
    expect(repository.opened.single.$3, 'c1');
  });
}
