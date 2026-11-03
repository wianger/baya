import 'package:app/acp/acp.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// The session's settings as the agent exposes them over ACP: model,
/// reasoning effort, mode, and anything else (`configOptions`), plus the
/// legacy mode list. A row opens its choices; picking one applies it.
Future<void> showSessionSettings(BuildContext context, {String? focus}) {
  final session = context.read<SessionController>();
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
    builder: (_) => ChangeNotifierProvider<SessionController>.value(
      value: session,
      child: _SettingsBody(focus: focus),
    ),
  );
}

class _SettingsBody extends StatefulWidget {
  const _SettingsBody({this.focus});

  /// Config id to open straight away (`model` from the composer chip).
  final String? focus;

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  /// The config option whose choices are open; `_modes` for the mode list.
  String? _open;
  String? _busy;

  static const _modes = '\u0000modes';

  @override
  void initState() {
    super.initState();
    final focus = widget.focus;
    if (focus != null) {
      final session = context.read<SessionController>();
      _open = session.configFor(focus)?.id;
    }
  }

  Future<void> _apply(Future<void> Function() change, String id) async {
    setState(() => _busy = id);
    try {
      await change();
      if (mounted) setState(() => _open = null);
    } catch (error) {
      if (mounted) {
        await showBayaNotice(
          context,
          title: context.l10n.settingChangeFailed,
          message: '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final mq = MediaQuery.of(context);
    final open = _open == _modes
        ? null
        : session.configOptions.where((o) => o.id == _open).firstOrNull;
    final showingModes = _open == _modes && session.modes != null;
    final Widget body;
    if (open != null) {
      body = _Choices(
        title: open.name,
        busy: _busy == open.id,
        onBack: () => setState(() => _open = null),
        choices: [
          for (final choice in open.choices)
            (
              id: choice.value,
              label: choice.name,
              detail: choice.description,
              group: choice.group,
              selected: choice.value == open.value,
            ),
        ],
        onPick: (value) =>
            _apply(() => session.setConfig(open.id, value), open.id),
      );
    } else if (showingModes) {
      final modes = session.modes!;
      body = _Choices(
        title: context.l10n.mode,
        busy: _busy == _modes,
        onBack: () => setState(() => _open = null),
        choices: [
          for (final mode in modes.available)
            (
              id: mode.id,
              label: mode.name,
              detail: mode.description,
              group: null,
              selected: mode.id == modes.currentModeId,
            ),
        ],
        onPick: (id) => _apply(() => session.setMode(id), _modes),
      );
    } else {
      body = _Overview(
        session: session,
        busy: _busy,
        onOpen: (id) => setState(() => _open = id),
        onToggle: (option, value) =>
            _apply(() => session.setConfig(option.id, value), option.id),
        modesId: _modes,
      );
    }
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * .84),
        child: BayaSurface(
          role: BayaSurfaceRole.overlay,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(34)),
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
          child: AnimatedSize(
            duration: BayaMotion.standard,
            curve: BayaMotion.enter,
            alignment: Alignment.topCenter,
            child: body,
          ),
        ),
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({
    required this.session,
    required this.busy,
    required this.onOpen,
    required this.onToggle,
    required this.modesId,
  });

  final SessionController session;
  final String? busy;
  final ValueChanged<String> onOpen;
  final void Function(ConfigOption option, bool value) onToggle;
  final String modesId;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final modes = session.modes;
    final usage = session.usage;
    final rows = <Widget>[
      for (final option in session.configOptions)
        if (option.isBoolean)
          SwitchListTile(
            key: ValueKey('setting-${option.id}'),
            value: option.enabled ?? false,
            onChanged: busy == null ? (value) => onToggle(option, value) : null,
            title: Text(option.name),
            subtitle: option.description == null
                ? null
                : Text(option.description!),
          )
        else
          _Row(
            key: ValueKey('setting-${option.id}'),
            icon: _iconFor(option.category),
            label: option.name,
            value: option.current?.name ?? option.value ?? '—',
            busy: busy == option.id,
            onTap: option.choices.isEmpty ? null : () => onOpen(option.id),
          ),
      // ACP: an agent that offers a `mode` config option manages modes there.
      if (modes != null &&
          modes.available.isNotEmpty &&
          session.configFor('mode') == null)
        _Row(
          key: const ValueKey('setting-mode'),
          icon: LucideIcons.toggleRight,
          label: context.l10n.mode,
          value:
              modes.available
                  .where((m) => m.id == modes.currentModeId)
                  .firstOrNull
                  ?.name ??
              modes.currentModeId,
          busy: busy == modesId,
          onTap: () => onOpen(modesId),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Text(
            session.agentName.isEmpty
                ? context.l10n.settings
                : session.agentName,
            style: context.typo.sansBody.copyWith(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            child: Text(
              context.l10n.noSessionSettings,
              style: context.typo.sansBody.copyWith(color: colors.muted),
            ),
          )
        else
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: rows,
              ),
            ),
          ),
        if (usage != null) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: _UsageBar(usage: usage),
          ),
        ],
      ],
    );
  }

  static IconData _iconFor(String? category) => switch (category) {
    'model' => LucideIcons.cpu,
    'thought_level' => LucideIcons.brain,
    'mode' => LucideIcons.toggleRight,
    _ => LucideIcons.slidersHorizontal,
  };
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.usage});

  final Usage usage;

  String _count(int value) => value.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (match) => '${match[1]},',
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final cost = usage.cost;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              context.l10n.contextUsage,
              style: context.typo.sansBody.copyWith(
                fontSize: 13,
                color: colors.muted2,
              ),
            ),
            const Spacer(),
            Text(
              '${_count(usage.used)} / ${_count(usage.size)}',
              style: context.typo.monoSmall.copyWith(
                fontSize: 12,
                color: colors.muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: usage.fraction,
            minHeight: 5,
            color: colors.accent,
            backgroundColor: colors.border,
          ),
        ),
        if (cost != null) ...[
          const SizedBox(height: 6),
          Text(
            context.l10n.sessionCost(
              '${cost.toStringAsFixed(2)} ${usage.currency ?? ''}'.trim(),
            ),
            style: context.typo.sansBody.copyWith(
              fontSize: 12,
              color: colors.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 19, color: colors.muted2),
            const SizedBox(width: 14),
            Text(
              label,
              style: context.typo.sansBody.copyWith(
                fontSize: 15.5,
                color: colors.text,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typo.sansBody.copyWith(
                  fontSize: 14.5,
                  color: colors.muted,
                ),
              ),
            ),
            const SizedBox(width: 6),
            busy
                ? SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: colors.muted,
                    ),
                  )
                : Icon(LucideIcons.chevronRight, size: 16, color: colors.muted),
          ],
        ),
      ),
    );
  }
}

typedef _Choice = ({
  String id,
  String label,
  String? detail,
  String? group,
  bool selected,
});

class _Choices extends StatelessWidget {
  const _Choices({
    required this.title,
    required this.choices,
    required this.busy,
    required this.onBack,
    required this.onPick,
  });

  final String title;
  final List<_Choice> choices;
  final bool busy;
  final VoidCallback onBack;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final rows = <Widget>[];
    String? group;
    for (final choice in choices) {
      if (choice.group != null && choice.group != group) {
        group = choice.group;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Text(
              group!,
              style: context.typo.sansBody.copyWith(
                fontSize: 12,
                color: colors.muted,
              ),
            ),
          ),
        );
      }
      rows.add(
        InkWell(
          key: ValueKey('choice-${choice.id}'),
          borderRadius: BorderRadius.circular(18),
          onTap: busy || choice.selected ? null : () => onPick(choice.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        choice.label,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 15.5,
                          color: colors.text,
                          fontWeight: choice.selected ? FontWeight.w600 : null,
                        ),
                      ),
                      if (choice.detail != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            choice.detail!,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 12.5,
                              color: colors.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (choice.selected)
                  Icon(LucideIcons.check, size: 17, color: colors.accent),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: context.l10n.back,
              onPressed: onBack,
              icon: Icon(LucideIcons.chevronLeft, size: 20, color: colors.text),
            ),
            Expanded(
              child: Text(
                title,
                style: context.typo.sansBody.copyWith(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
            ),
            if (busy)
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: colors.muted,
                  ),
                ),
              ),
          ],
        ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      ],
    );
  }
}
