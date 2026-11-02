import 'package:app/ui/core/themes/themes.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_top_right_popover.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../states/context_usage_state.dart';
import '../viewmodels/context_usage_viewmodel.dart';

Future<void> showContextUsage(BuildContext context, {Rect? origin}) async {
  final vm = context.read<ContextUsageViewModel>();
  vm.refresh();
  await showBayaTopRightPopover<void>(
    context: context,
    origin: origin,
    width: 328,
    surfaceRadius: 24,
    child: KeyedSubtree(
      key: const Key('context-usage-popover'),
      child: ChangeNotifierProvider.value(
        value: vm,
        child: const ContextUsageSheet(),
      ),
    ),
  );
}

class ContextUsageSheet extends StatelessWidget {
  const ContextUsageSheet({super.key});
  String _tokens(int? value) => value == null
      ? appL10n.notReported
      : value.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (match) => '${match[1]},',
        );
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ContextUsageViewModel>();
    final state = vm.state;
    return BayaSurface(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.contextUsage,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: context.l10n.refreshContextUsage,
                  onPressed: state is ContextUsageLoading ? null : vm.refresh,
                  icon: const Icon(Icons.refresh, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (state is ContextUsageLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(),
                ),
              ),
            if (state is ContextUsageError) Text(state.message),
            if (state is ContextUsageReady) ...[
              _row(
                context,
                context.l10n.usedTokens,
                _tokens(state.usage.tokens),
              ),
              _row(
                context,
                context.l10n.contextWindow,
                _tokens(state.usage.window),
              ),
              _row(
                context,
                context.l10n.usage,
                state.usage.percent == null
                    ? context.l10n.notReported
                    : '${state.usage.percent!.toStringAsFixed(1)}%',
              ),
              const SizedBox(height: 12),
              if (state.usage.percent != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(
                      begin: 0,
                      end: (state.usage.percent! / 100).clamp(0.0, 1.0),
                    ),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : BayaMotion.emphasized,
                    curve: BayaMotion.enter,
                    builder: (context, value, _) =>
                        LinearProgressIndicator(minHeight: 6, value: value),
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                'Reported by ${switch (state.usage.source) {
                  'codex' => 'Codex',
                  'deepseek' => 'DeepSeek',
                  _ => 'Pi',
                }}. Usage is an estimate and may be unavailable before the first response or after compaction.',
                style: context.typo.sansBody.copyWith(
                  color: context.colors.muted,
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: context.typo.monoSmall),
      ],
    ),
  );
}
