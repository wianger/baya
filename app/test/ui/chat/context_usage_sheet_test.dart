import 'package:app/domain/contracts/context_usage_repository.dart';
import 'package:app/domain/entities/context_usage.dart';
import 'package:app/ui/chat/context/viewmodels/context_usage_viewmodel.dart';
import 'package:app/ui/chat/context/widgets/context_usage_sheet.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Repo implements IContextUsageRepository {
  _Repo(this.value);
  final ContextUsageSnapshot value;
  @override
  Future<ContextUsageSnapshot> fetch() async => value;
}

void main() {
  testWidgets('context popover shows token counts, capacity and percentage', (
    tester,
  ) async {
    final vm = ContextUsageViewModel(
      _Repo(
        const ContextUsageSnapshot(
          tokens: 80_000,
          window: 200_000,
          source: 'pi',
        ),
      ),
    );
    addTearDown(vm.dispose);
    await vm.refresh();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vm,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const Scaffold(body: ContextUsageSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('80,000'), findsOneWidget);
    expect(find.text('200,000'), findsOneWidget);
    expect(find.text('40.0%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .4,
    );
  });
  testWidgets(
    'unknown usage is clearly unreported and has no fake progress bar',
    (tester) async {
      final vm = ContextUsageViewModel(
        _Repo(const ContextUsageSnapshot(window: 200_000)),
      );
      addTearDown(vm.dispose);
      await vm.refresh();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: vm,
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const Scaffold(body: ContextUsageSheet()),
          ),
        ),
      );
      expect(find.text('Not reported'), findsNWidgets(2));
      expect(find.text('0.0%'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );

  testWidgets('context popover identifies DeepSeek Harness as the source', (
    tester,
  ) async {
    final vm = ContextUsageViewModel(
      _Repo(
        const ContextUsageSnapshot(
          tokens: 10_000,
          window: 100_000,
          source: 'deepseek',
        ),
      ),
    );
    addTearDown(vm.dispose);
    await vm.refresh();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vm,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const Scaffold(body: ContextUsageSheet()),
        ),
      ),
    );
    expect(find.textContaining('Reported by DeepSeek.'), findsOneWidget);
  });
}
