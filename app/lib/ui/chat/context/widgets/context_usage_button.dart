import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_top_right_popover.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../states/context_usage_state.dart';
import '../viewmodels/context_usage_viewmodel.dart';
import 'context_usage_sheet.dart';

/// A bounded, determinate ring. Unknown usage is never presented as zero.
class ContextUsageButton extends StatefulWidget {
  const ContextUsageButton({
    super.key,
    required this.enabled,
    required this.working,
    required this.messageCount,
  });

  final bool enabled;
  final bool working;
  final int messageCount;

  @override
  State<ContextUsageButton> createState() => _ContextUsageButtonState();
}

class _ContextUsageButtonState extends State<ContextUsageButton>
    with WidgetsBindingObserver {
  ContextUsageViewModel? _viewModel;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vm = context.read<ContextUsageViewModel>();
    if (!identical(vm, _viewModel)) {
      _viewModel = vm;
      _refreshAfterFrame();
    }
  }

  @override
  void didUpdateWidget(ContextUsageButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!oldWidget.enabled && widget.enabled) ||
        (!widget.working &&
            (oldWidget.working ||
                oldWidget.messageCount != widget.messageCount))) {
      _refreshAfterFrame();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAfterFrame();
  }

  void _refreshAfterFrame() {
    if (_scheduled || !widget.enabled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && widget.enabled) _viewModel?.refresh();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ContextUsageViewModel>().state;
    final reported = state is ContextUsageReady ? state.usage.percent : null;
    final percent =
        widget.enabled && reported != null && reported.isFinite && reported >= 0
        ? reported
        : null;
    final loading = widget.enabled && state is ContextUsageLoading;
    final value = !widget.enabled
        ? 'Offline'
        : percent != null
        ? '${percent.toStringAsFixed(1)}%'
        : loading
        ? 'Loading'
        : 'Not reported';
    final colors = context.colors;
    return Semantics(
      value: value,
      child: IconButton(
        tooltip: 'Context usage',
        onPressed: widget.enabled
            ? () => showContextUsage(context, origin: bayaRectOf(context))
            : null,
        icon: ExcludeSemantics(
          child: SizedBox.square(
            dimension: 32,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.border, width: 2.5),
                    ),
                  ),
                ),
                if (percent != null)
                  Positioned.fill(
                    child: CircularProgressIndicator(
                      value: (percent / 100).clamp(0.0, 1.0),
                      strokeWidth: 2.5,
                      strokeAlign: -1,
                      strokeCap: StrokeCap.round,
                      color: colors.accent,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(5),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      percent != null
                          ? '${percent.round()}%'
                          : loading
                          ? '…'
                          : '—',
                      style: context.typo.sansBody.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: widget.enabled ? colors.text : colors.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
