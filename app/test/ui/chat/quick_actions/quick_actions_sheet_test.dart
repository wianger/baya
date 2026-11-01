// Plan/28 Wave C — Quick Actions bottom sheet widget tests.
//
// These drive the REAL `QuickActionsSheetBody` (not a replica harness) so
// the close-on-success, success/error toast, and `session_new` reset wiring
// are actually exercised. The ViewModel is built with a fake
// `IActionsRepository` so we don't spin up the DI graph or a live channel.

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/quick_actions/states/quick_actions_state.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:app/ui/chat/quick_actions/widgets/model_picker_sheet.dart';
import 'package:app/ui/chat/quick_actions/widgets/quick_actions_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeRepo implements IActionsRepository {
  int compactCalls = 0;
  int newSessionCalls = 0;
  ThinkingLevel? thinking;
  WireModel? modelArg;

  /// When set, the matching action throws [ActionFailure] to exercise the
  /// failure path (error toast + sheet stays open).
  bool failCompact = false;
  bool failNewSession = false;
  ModelsCatalogue catalogue = const ModelsCatalogue(models: [], current: null);
  final List<ModelsCatalogue> catalogueQueue = [];
  final List<bool> modelListForceRefreshCalls = [];

  @override
  ActiveRoomMeta get activeRoomMeta => const ActiveRoomMeta();

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream =>
      const Stream<ActiveRoomMeta>.empty();

  @override
  Future<void> compact() async {
    compactCalls++;
    if (failCompact) throw const ActionFailure('compact boom');
  }

  @override
  Future<void> newSession() async {
    newSessionCalls++;
    if (failNewSession) throw const ActionFailure('new boom');
  }

  @override
  Future<void> setModel(String provider, String modelId) async {
    modelArg = WireModel(
      id: modelId,
      provider: provider,
      name: modelId,
      reasoning: false,
      contextWindow: 0,
    );
  }

  @override
  Future<void> setThinking(ThinkingLevel level) async {
    thinking = level;
  }

  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async {
    modelListForceRefreshCalls.add(forceRefresh);
    if (catalogueQueue.isNotEmpty) return catalogueQueue.removeAt(0);
    return catalogue;
  }

  @override
  Future<SessionInventorySnapshot> listSessionsInventory() async =>
      const SessionInventorySnapshot(sessionKeys: {}, scannedAt: 0);

  @override
  void dispose() {}
}

/// Opens the real sheet body over a host Scaffold. Returns the fake repo and
/// a list appended to by the `onSessionReset` callback.
Future<({_FakeRepo repo, List<int> resetCalls})> _openSheet(
  WidgetTester tester, {
  bool failCompact = false,
  bool failNewSession = false,
  ModelsCatalogue catalogue = const ModelsCatalogue(models: [], current: null),
}) async {
  final repo = _FakeRepo()
    ..failCompact = failCompact
    ..failNewSession = failNewSession
    ..catalogue = catalogue;
  final vm = QuickActionsViewModel(repo);
  final resetCalls = <int>[];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () {
              final messenger = ScaffoldMessenger.of(ctx);
              showModalBottomSheet<void>(
                context: ctx,
                // Mirror the production entry point so the full body has room
                // (otherwise the Column overflows the half-height default).
                isScrollControlled: true,
                builder: (_) =>
                    ChangeNotifierProvider<QuickActionsViewModel>.value(
                      value: vm,
                      child: QuickActionsSheetBody(
                        messenger: messenger,
                        onSessionReset: () async => resetCalls.add(1),
                      ),
                    ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (repo: repo, resetCalls: resetCalls);
}

void main() {
  testWidgets(
    'compact and new-session buttons are gone in favour of slash commands',
    (tester) async {
      await _openSheet(tester);
      expect(find.byKey(const Key('qa-compact')), findsNothing);
      expect(find.byKey(const Key('qa-new-session')), findsNothing);
      expect(find.text('Session'), findsOneWidget);
    },
  );
  testWidgets('thinking segment forwards level to repo', (tester) async {
    final s = await _openSheet(tester);
    await tester.tap(find.byKey(const Key('qa-thinking-medium')));
    await tester.pumpAndSettle();
    expect(s.repo.thinking, ThinkingLevel.medium);
  });

  testWidgets('model picker uses the Claude-style model and effort list', (
    tester,
  ) async {
    const opus = WireModel(
      id: 'opus',
      provider: 'anthropic',
      name: 'Opus 5.5',
      reasoning: true,
      contextWindow: 200000,
    );
    const haiku = WireModel(
      id: 'haiku',
      provider: 'anthropic',
      name: 'Haiku 5.5',
      reasoning: false,
      contextWindow: 64000,
    );
    await _openSheet(
      tester,
      catalogue: const ModelsCatalogue(models: [opus, haiku], current: opus),
    );
    await tester.tap(find.byKey(const Key('qa-model-row')));
    await tester.pumpAndSettle();

    final picker = find.byKey(const Key('model-picker-sheet'));
    // Level 1: the Model + Effort summary rows.
    expect(picker, findsOneWidget);
    expect(tester.getSize(picker).height, lessThan(240));
    expect(
      find.descendant(of: picker, matching: find.text('Opus 5.5')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('model-picker-model')), findsOneWidget);
    expect(find.byKey(const Key('model-picker-effort')), findsOneWidget);

    await tester.tap(find.byKey(const Key('model-picker-model')));
    await tester.pumpAndSettle();

    // Level 2: the full model list.
    expect(find.text('Select model'), findsOneWidget);
    expect(
      find.descendant(of: picker, matching: find.text('Opus 5.5')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: picker, matching: find.text('Haiku 5.5')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: picker, matching: find.text('Reasoning')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('model-picker-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('model-picker-effort')));
    await tester.pumpAndSettle();
    expect(find.text('Reasoning effort'), findsOneWidget);
    expect(find.text('Extra high'), findsOneWidget);
  });

  testWidgets('model picker refreshes a transient empty catalogue', (
    tester,
  ) async {
    const sonnet = WireModel(
      id: 'sonnet',
      provider: 'anthropic',
      name: 'Sonnet 5.5',
      reasoning: true,
      contextWindow: 200000,
    );
    final repo = _FakeRepo()
      ..catalogueQueue.addAll(const [
        ModelsCatalogue(models: [], current: null),
        ModelsCatalogue(models: [sonnet], current: sonnet),
      ]);
    final vm = QuickActionsViewModel(repo);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ChangeNotifierProvider.value(
              value: vm,
              child: ElevatedButton(
                onPressed: () => showModelPickerSheet(ctx, vm: vm),
                child: const Text('open picker'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open picker'));
    await tester.pumpAndSettle();

    expect(repo.modelListForceRefreshCalls, [false, true]);
    expect(find.text('Sonnet 5.5'), findsOneWidget);
  });

  testWidgets('model picker empty state offers a retry', (tester) async {
    final repo = _FakeRepo();
    final vm = QuickActionsViewModel(repo);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ChangeNotifierProvider.value(
              value: vm,
              child: ElevatedButton(
                onPressed: () => showModelPickerSheet(ctx, vm: vm),
                child: const Text('open picker'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open picker'));
    await tester.pumpAndSettle();
    expect(find.text('No models available'), findsOneWidget);

    await tester.tap(find.byKey(const Key('model-picker-empty-retry')));
    await tester.pumpAndSettle();

    expect(repo.modelListForceRefreshCalls, [false, true, true]);
  });

  testWidgets('model picker height grows with the visible option count', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<double> measure(int count) async {
      final models = List.generate(
        count,
        (index) => WireModel(
          id: 'model-$index',
          provider: 'provider',
          name: 'Model $index',
          reasoning: index.isEven,
          contextWindow: 128000,
        ),
      );
      await _openSheet(
        tester,
        catalogue: ModelsCatalogue(models: models, current: models.first),
      );
      await tester.tap(find.byKey(const Key('qa-model-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('model-picker-model')));
      await tester.pumpAndSettle();
      final height = tester
          .getSize(find.byKey(const Key('model-picker-sheet')))
          .height;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      return height;
    }

    final compact = await measure(2);
    final expanded = await measure(12);

    expect(compact, lessThan(420));
    expect(expanded, greaterThan(compact));
    expect(expanded, lessThanOrEqualTo(844 * .84));
  });

  test('QuickActionsState equality covers idle + busy', () {
    expect(const QuickActionsIdle(), const QuickActionsIdle());
    expect(
      const QuickActionsIdle(currentThinking: ThinkingLevel.low),
      const QuickActionsIdle(currentThinking: ThinkingLevel.low),
    );
    expect(
      const QuickActionsBusy(action: ActionName.modelSet),
      const QuickActionsBusy(action: ActionName.modelSet),
    );
  });
}
