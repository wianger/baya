import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/workspaces/widgets/agent_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(
  List<WorkspaceAgent> agents,
  ValueChanged<WorkspaceAgent> onChanged,
) => MaterialApp(
  theme: buildDarkTheme(),
  home: Scaffold(
    body: AgentPickerField(
      agents: agents,
      selected: agents.first,
      computerLabel: 'Computer',
      enabled: true,
      onChanged: onChanged,
    ),
  ),
);

void main() {
  testWidgets(
    'searches a larger catalog by id and returns the selected future agent',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      WorkspaceAgent? picked;
      await tester.pumpWidget(
        wrap(
          List.generate(
            12,
            (index) => WorkspaceAgent(
              id: 'agent-$index',
              label: 'Agent $index',
              description: 'Provider $index',
            ),
          ),
          (agent) => picked = agent,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('workspace-agent-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('agent-picker-search')),
        'agent-11',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('agent-option-agent-11')));
      await tester.pumpAndSettle();
      expect(picked!.id, 'agent-11');
      expect(find.byKey(const ValueKey('agent-picker-sheet')), findsNothing);
    },
  );

  testWidgets('unavailable entries show a reason and cannot be selected', (
    tester,
  ) async {
    WorkspaceAgent? picked;
    await tester.pumpWidget(
      wrap(const [
        WorkspaceAgent.pi,
        WorkspaceAgent(
          id: 'other',
          label: 'Other Agent',
          available: false,
          unavailableReason: 'Sign-in required',
        ),
      ], (agent) => picked = agent),
    );
    await tester.tap(find.byKey(const ValueKey('workspace-agent-picker')));
    await tester.pumpAndSettle();
    expect(find.text('Sign-in required'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-option-other')));
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(find.byKey(const ValueKey('agent-picker-sheet')), findsOneWidget);
  });

  testWidgets('agent picker shrinks to fit a short catalog', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      wrap(const [
        WorkspaceAgent.pi,
        WorkspaceAgent(
          id: 'codex',
          label: 'Codex',
          description: 'OpenAI coding agent',
        ),
      ], (_) {}),
    );
    await tester.tap(find.byKey(const ValueKey('workspace-agent-picker')));
    await tester.pumpAndSettle();

    final height = tester
        .getSize(find.byKey(const ValueKey('agent-picker-sheet')))
        .height;
    expect(height, lessThan(500));
  });
}
