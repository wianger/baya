import 'package:app/domain/contracts/context_usage_repository.dart';
import 'package:app/domain/entities/context_usage.dart';
import 'package:app/ui/chat/context/viewmodels/context_usage_viewmodel.dart';
import 'package:app/ui/chat/context/widgets/context_usage_button.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Repository implements IContextUsageRepository {
  ContextUsageSnapshot value = const ContextUsageSnapshot(
    tokens: 40_000,
    window: 200_000,
    source: 'pi',
  );
  int requests = 0;

  @override
  Future<ContextUsageSnapshot> fetch() async {
    requests++;
    return value;
  }
}

Widget _app(
  ContextUsageViewModel vm, {
  bool enabled = true,
  bool working = false,
  int messages = 1,
}) => ChangeNotifierProvider.value(
  value: vm,
  child: MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 8, right: 16),
          child: ContextUsageButton(
            enabled: enabled,
            working: working,
            messageCount: messages,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'loads usage automatically and opens the existing token details',
    (tester) async {
      final repository = _Repository();
      final vm = ContextUsageViewModel(repository);
      addTearDown(vm.dispose);
      await tester.pumpWidget(_app(vm));
      await tester.pumpAndSettle();
      expect(repository.requests, 1);
      expect(find.text('20%'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        .2,
      );
      final trigger = find.byTooltip('Context usage');
      final triggerRect = tester.getRect(trigger);
      await tester.tap(trigger);
      await tester.pump();
      final popover = find.byKey(const Key('context-usage-popover'));
      final contentOpacity = find.byKey(
        const Key('baya-surface-content-opacity'),
      );
      final startRect = tester.getRect(popover);
      expect(
        tester.widget<Opacity>(contentOpacity).opacity,
        lessThan(0.02),
        reason:
            'the glass leads while the contents remain hidden at the origin',
      );
      await tester.pump(const Duration(milliseconds: 190));
      final middleRect = tester.getRect(popover);
      expect(tester.widget<Opacity>(contentOpacity).opacity, greaterThan(.2));
      await tester.pumpAndSettle();
      expect(repository.requests, 2);
      expect(find.text('40,000'), findsOneWidget);
      expect(find.text('200,000'), findsOneWidget);
      expect(find.text('20.0%'), findsOneWidget);
      expect(popover, findsOneWidget);
      final popoverRect = tester.getRect(popover);
      final screenWidth =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(startRect.width, closeTo(triggerRect.width, 1));
      expect(middleRect.width, greaterThan(startRect.width + 20));
      expect(popoverRect.width, greaterThan(middleRect.width));
      expect(popoverRect.top, lessThan(triggerRect.bottom));
      expect(popoverRect.right, closeTo(screenWidth - 12, 0.5));
      expect(popoverRect.center.dy, lessThan(screenHeight * .5));
      expect(tester.widget<Opacity>(contentOpacity).opacity, 1);
    },
  );

  testWidgets(
    'refreshes after a turn and reconnect without polling streaming',
    (tester) async {
      final repository = _Repository();
      final vm = ContextUsageViewModel(repository);
      addTearDown(vm.dispose);
      await tester.pumpWidget(_app(vm));
      await tester.pumpAndSettle();
      repository.value = const ContextUsageSnapshot(
        tokens: 120_000,
        window: 200_000,
      );
      await tester.pumpWidget(_app(vm, working: true, messages: 2));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_app(vm, working: true, messages: 3));
      await tester.pumpAndSettle();
      expect(repository.requests, 1);
      await tester.pumpWidget(_app(vm, messages: 4));
      await tester.pumpAndSettle();
      expect(repository.requests, 2);
      expect(find.text('60%'), findsOneWidget);
      await tester.pumpWidget(_app(vm, enabled: false, messages: 4));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.byTooltip('Context usage'));
      await tester.pumpAndSettle();
      expect(repository.requests, 2);
      await tester.pumpWidget(_app(vm, messages: 4));
      await tester.pumpAndSettle();
      expect(repository.requests, 3);
    },
  );

  testWidgets('closing reverses the morph back toward the trigger', (
    tester,
  ) async {
    final repository = _Repository();
    final vm = ContextUsageViewModel(repository);
    addTearDown(vm.dispose);
    await tester.pumpWidget(_app(vm));
    await tester.pumpAndSettle();
    final trigger = find.byTooltip('Context usage');
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final popover = find.byKey(const Key('context-usage-popover'));
    final openRect = tester.getRect(popover);

    await tester.tapAt(const Offset(20, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final closingRect = tester.getRect(popover);
    expect(closingRect.width, lessThan(openRect.width));

    await tester.pumpAndSettle();
    expect(popover, findsNothing);
  });

  testWidgets(
    'unknown usage is distinct from zero and overfull usage is bounded',
    (tester) async {
      final repository = _Repository()
        ..value = const ContextUsageSnapshot(window: 200_000);
      final vm = ContextUsageViewModel(repository);
      addTearDown(vm.dispose);
      await tester.pumpWidget(_app(vm));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      repository.value = const ContextUsageSnapshot(tokens: 0, window: 200_000);
      await vm.refresh();
      await tester.pumpAndSettle();
      expect(find.text('0%'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0,
      );
      repository.value = const ContextUsageSnapshot(
        tokens: 250_000,
        window: 200_000,
      );
      await vm.refresh();
      await tester.pumpAndSettle();
      expect(find.text('125%'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
