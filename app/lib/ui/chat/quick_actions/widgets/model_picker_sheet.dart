import 'package:app/data/actions/actions_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Opens the model chooser on its own, without the intermediate Quick Actions
/// sheet. The composer's model button uses this so one tap lands directly on
/// the Claude-style model list.
Future<void> showStandaloneModelPicker(BuildContext context) {
  final vm = context.read<QuickActionsViewModel>();
  final errorContext = context;
  return showModelPickerSheet(
    context,
    vm: vm,
    onError: (message) {
      if (!errorContext.mounted) return;
      showBayaNotice(
        errorContext,
        title: 'Model change failed',
        message: message,
      );
    },
  );
}

/// Apple-style model chooser with a single calm list and an optional effort
/// picker, matching the hierarchy used by Claude mobile.
Future<void> showModelPickerSheet(
  BuildContext context, {
  required QuickActionsViewModel vm,
  ValueChanged<String>? onError,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .34),
    isScrollControlled: true,
    showDragHandle: false,
    sheetAnimationStyle: AnimationStyle(
      duration: BayaMotion.standard,
      curve: BayaMotion.enter,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(38)),
    ),
    builder: (ctx) => ChangeNotifierProvider<QuickActionsViewModel>.value(
      value: vm,
      child: _ModelPickerBody(onError: onError),
    ),
  );
}

class _ModelPickerBody extends StatefulWidget {
  const _ModelPickerBody({this.onError});

  final ValueChanged<String>? onError;

  @override
  State<_ModelPickerBody> createState() => _ModelPickerBodyState();
}

class _ModelPickerBodyState extends State<_ModelPickerBody> {
  late Future<ModelsCatalogue> _future;

  /// Claude-style two-level picker: the first sheet lists the current Model and
  /// Effort as summary rows; tapping either pushes the detail list.
  bool _editingModel = false;
  bool _editingEffort = false;

  @override
  void initState() {
    super.initState();
    _future = _loadInitial();
  }

  /// An empty answer can be transient while a harness is still discovering
  /// providers. Retry once without the cached fast path before showing the
  /// actionable empty state.
  Future<ModelsCatalogue> _loadInitial() async {
    final catalogue = await _load(forceRefresh: false);
    if (catalogue.models.isNotEmpty) return catalogue;
    return _load(forceRefresh: true);
  }

  Future<ModelsCatalogue> _load({required bool forceRefresh}) {
    return context.read<QuickActionsViewModel>().loadModels(
      forceRefresh: forceRefresh,
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load(forceRefresh: true);
    });
    await _future.catchError((Object _) => const ModelsCatalogue(models: []));
  }

  Future<void> _onPick(WireModel model) async {
    final vm = context.read<QuickActionsViewModel>();
    try {
      await vm.setModel(model);
      if (mounted) Navigator.of(context).pop();
    } on ActionFailure catch (error) {
      // The owning quick-actions sheet surfaces action errors; the standalone
      // entry point routes them to a snackbar instead.
      widget.onError?.call(error.message);
    }
  }

  Future<void> _onPickEffort(ThinkingLevel level) async {
    final vm = context.read<QuickActionsViewModel>();
    try {
      await vm.setThinking(level);
      if (mounted) setState(() => _editingEffort = false);
    } on ActionFailure catch (error) {
      widget.onError?.call(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<QuickActionsViewModel>();
    final detail = _editingModel || _editingEffort;
    final mq = MediaQuery.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
        child: ConstrainedBox(
          // Lists shrink to their visible rows while this cap keeps long
          // catalogues usable and scrollable on compact screens.
          constraints: BoxConstraints(maxHeight: mq.size.height * .84),
          child: BayaGlassSurface(
            key: const Key('model-picker-sheet'),
            radius: 38,
            elevated: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 3,
                  decoration: BoxDecoration(
                    color: context.colors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 4),
                _Header(
                  title: _editingModel
                      ? 'Select model'
                      : _editingEffort
                      ? 'Reasoning effort'
                      : 'Model',
                  onRefresh: _editingModel || !detail ? _refresh : null,
                  onBack: _editingEffort || _editingModel
                      ? () => setState(() {
                          _editingModel = false;
                          _editingEffort = false;
                        })
                      : null,
                ),
                Flexible(
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : BayaMotion.standard,
                    switchInCurve: BayaMotion.enter,
                    switchOutCurve: BayaMotion.exit,
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...previousChildren, ?currentChild],
                    ),
                    child: _editingEffort
                        ? _EffortList(
                            key: const ValueKey('model-effort-list'),
                            current: vm.currentThinking,
                            levels:
                                vm.currentModel?.availableThinkingLevels ??
                                const <ThinkingLevel>[],
                            onPick: _onPickEffort,
                          )
                        : FutureBuilder<ModelsCatalogue>(
                            key: ValueKey(
                              _editingModel ? 'model-list' : 'model-summary',
                            ),
                            future: _future,
                            builder: (ctx, snap) {
                              if (snap.connectionState !=
                                  ConnectionState.done) {
                                return const _LoadingState();
                              }
                              if (snap.hasError) {
                                return _ErrorState(
                                  message: snap.error is ActionFailure
                                      ? (snap.error as ActionFailure).message
                                      : 'Failed to load models',
                                  onRetry: _refresh,
                                );
                              }
                              final catalogue = snap.data!;
                              if (catalogue.models.isEmpty) {
                                return _EmptyState(onRetry: _refresh);
                              }
                              final current = vm.currentThinking;
                              final selected = catalogue.current;
                              final effortLevels =
                                  selected?.availableThinkingLevels ??
                                  const <ThinkingLevel>[];
                              // Level 2: the full model list.
                              if (_editingModel) {
                                return ListView(
                                  shrinkWrap: true,
                                  physics: const ClampingScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    4,
                                    18,
                                    20,
                                  ),
                                  children: [
                                    _ModelList(
                                      models: catalogue.models,
                                      selected: selected,
                                      onPick: _onPick,
                                    ),
                                  ],
                                );
                              }
                              // Level 1: Model + Effort summary rows.
                              return ListView(
                                shrinkWrap: true,
                                physics: const ClampingScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  14,
                                ),
                                children: [
                                  _PickerRow(
                                    key: const Key('model-picker-model'),
                                    label: 'Model',
                                    value: selected?.name ?? 'Not reported',
                                    onTap: () =>
                                        setState(() => _editingModel = true),
                                  ),
                                  if (effortLevels.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    _PickerRow(
                                      key: const Key('model-picker-effort'),
                                      label: 'Effort',
                                      value:
                                          current == null ||
                                              !effortLevels.contains(current)
                                          ? 'Default'
                                          : _effortLabel(current),
                                      onTap: () =>
                                          setState(() => _editingEffort = true),
                                    ),
                                  ],
                                ],
                              );
                            },
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

  static String _effortLabel(ThinkingLevel level) => switch (level) {
    ThinkingLevel.off => 'Off',
    ThinkingLevel.minimal => 'Minimal',
    ThinkingLevel.low => 'Low',
    ThinkingLevel.medium => 'Medium',
    ThinkingLevel.high => 'High',
    ThinkingLevel.xhigh => 'Extra high',
    ThinkingLevel.max => 'Max',
    ThinkingLevel.ultra => 'Ultra',
  };
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.onRefresh, this.onBack});

  final String title;
  final VoidCallback? onRefresh;
  final VoidCallback? onBack;
  static const double _height = 48;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: _height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: BayaGlassSurface(
                role: BayaGlassRole.control,
                radius: 22,
                elevated: false,
                child: SizedBox.square(
                  dimension: 38,
                  child: IconButton(
                    key: const Key('model-picker-close'),
                    tooltip: onBack == null
                        ? 'Close model picker'
                        : 'Back to model summary',
                    onPressed: onBack ?? () => Navigator.of(context).pop(),
                    icon: Icon(
                      onBack == null ? LucideIcons.x : LucideIcons.chevronLeft,
                      size: 19,
                      color: colors.text,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Text(
            title,
            style: context.typo.sansBody.copyWith(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              letterSpacing: -.35,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: IconButton(
                key: const Key('model-picker-refresh'),
                tooltip: 'Refresh models',
                onPressed: onRefresh,
                icon: Icon(
                  LucideIcons.refreshCw,
                  size: 17,
                  color: onRefresh == null
                      ? colors.muted.withValues(alpha: .35)
                      : colors.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Level-1 summary row: a label with the current value and a chevron into the
/// detail list, matching Claude's Model/Effort hierarchy.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaGlassSurface(
      role: BayaGlassRole.content,
      radius: 22,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 1,
          ),
          title: Text(
            label,
            style: context.typo.sansBody.copyWith(
              fontSize: 14.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.typo.sansBody.copyWith(
              fontSize: 11.5,
              color: colors.muted,
            ),
          ),
          trailing: onTap == null
              ? null
              : Icon(LucideIcons.chevronRight, size: 18, color: colors.muted),
          onTap: onTap,
        ),
      ),
    );
  }
}

/// Level-2 effort list.
class _EffortList extends StatelessWidget {
  const _EffortList({
    super.key,
    required this.current,
    required this.levels,
    required this.onPick,
  });

  final ThinkingLevel? current;
  final List<ThinkingLevel> levels;
  final ValueChanged<ThinkingLevel> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListView(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
      children: [
        BayaGlassSurface(
          role: BayaGlassRole.content,
          radius: 22,
          elevated: false,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var index = 0; index < levels.length; index++) ...[
                  ListTile(
                    key: ValueKey(
                      'model-picker-effort-${_ModelPickerBodyState._effortLabel(levels[index])}',
                    ),
                    title: Text(
                      _ModelPickerBodyState._effortLabel(levels[index]),
                    ),
                    trailing: levels[index] == current
                        ? Icon(
                            LucideIcons.check,
                            size: 19,
                            color: colors.accent,
                          )
                        : null,
                    onTap: () => onPick(levels[index]),
                  ),
                  if (index != levels.length - 1)
                    Divider(
                      height: 1,
                      indent: 18,
                      endIndent: 18,
                      color: colors.border.withValues(alpha: .72),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ModelList extends StatelessWidget {
  const _ModelList({
    required this.models,
    required this.selected,
    required this.onPick,
  });

  final List<WireModel> models;
  final WireModel? selected;
  final ValueChanged<WireModel> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaGlassSurface(
      role: BayaGlassRole.content,
      radius: 26,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(26),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var index = 0; index < models.length; index++) ...[
              _ModelTile(
                model: models[index],
                current:
                    selected?.id == models[index].id &&
                    selected?.provider == models[index].provider,
                onTap: () => onPick(models[index]),
              ),
              if (index != models.length - 1)
                Divider(
                  height: 1,
                  indent: 18,
                  endIndent: 18,
                  color: colors.border.withValues(alpha: .72),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.current,
    required this.onTap,
  });

  final WireModel model;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 15, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          model.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (model.reasoning) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.accent.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Reasoning',
                            style: context.typo.sansBody.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: colors.muted2,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _subtitle(model),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 12,
                      color: colors.muted,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            if (current) ...[
              const SizedBox(width: 12),
              Icon(LucideIcons.check, size: 20, color: colors.accent),
            ],
          ],
        ),
      ),
    );
  }

  static String _subtitle(WireModel model) {
    final pieces = <String>[
      model.provider,
      if (model.contextWindow > 0)
        '${(model.contextWindow / 1000).round()}k context',
      if (model.vision) 'vision',
    ];
    return pieces.join(' · ');
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 160,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'No models available',
              style: TextStyle(fontSize: 13, color: context.colors.muted),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('model-picker-empty-retry'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.error, fontSize: 13),
          ),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
