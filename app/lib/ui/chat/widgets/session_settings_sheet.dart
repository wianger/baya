import 'package:app/acp/acp.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_dialog.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// How full the agent's context is, from the header's ring.
Future<void> showContextUsage(BuildContext context) {
  final session = context.read<SessionController>();
  return showBayaSheet<void>(
    context,
    sheetKey: const Key('context-sheet'),
    title: context.l10n.contextUsage,
    builder: (_) => ChangeNotifierProvider<SessionController>.value(
      value: session,
      child: const _ContextSheet(),
    ),
  );
}

class _ContextSheet extends StatelessWidget {
  const _ContextSheet();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final usage = session.usage;
    final colors = context.colors;
    final canCompact = session.commands.any((c) => c.name == 'compact');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (usage == null)
          Text(
            context.l10n.notReported,
            style: context.typo.sansBody.copyWith(color: colors.muted),
          )
        else
          _UsageBar(usage: usage),
        if (canCompact) ...[
          const SizedBox(height: 18),
          OutlinedButton.icon(
            key: const Key('context-compact'),
            onPressed: session.working
                ? null
                : () {
                    Navigator.of(context).pop();
                    session.prompt('/compact');
                  },
            icon: const Icon(LucideIcons.foldVertical, size: 16),
            label: Text(context.l10n.compactContext),
          ),
        ],
      ],
    );
  }
}

/// The session's settings as the agent exposes them over ACP: model,
/// reasoning effort, mode, and anything else (`configOptions`), plus the
/// mode list. A row opens its choices; picking one applies it.
Future<void> showSessionSettings(BuildContext context, {String? focus}) {
  final session = context.read<SessionController>();
  return showBayaSheet<void>(
    context,
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
    return AnimatedSize(
      duration: BayaMotion.standard,
      curve: BayaMotion.enter,
      alignment: Alignment.topCenter,
      child: body,
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
    final rows = <Widget>[
      for (final option in session.configOptions)
        if (option.isBoolean)
          BayaRow(
            key: ValueKey('setting-${option.id}'),
            icon: LucideIcons.toggleRight,
            label: option.name,
            subtitle: option.description,
            trailing: Switch(
              value: option.enabled ?? false,
              onChanged: busy == null
                  ? (value) => onToggle(option, value)
                  : null,
            ),
          )
        else
          BayaRow(
            key: ValueKey('setting-${option.id}'),
            icon: _iconFor(option.category),
            label: option.name,
            value: option.current?.name ?? option.value ?? '—',
            chevron: busy != option.id,
            trailing: busy == option.id ? const _Busy() : null,
            onTap: option.choices.isEmpty || busy != null
                ? null
                : () => onOpen(option.id),
          ),
      // ACP: an agent that offers a `mode` config option manages modes there.
      if (modes != null &&
          modes.available.isNotEmpty &&
          session.configFor('mode') == null)
        BayaRow(
          key: const ValueKey('setting-mode'),
          icon: LucideIcons.toggleRight,
          label: context.l10n.mode,
          value:
              modes.available
                  .where((m) => m.id == modes.currentModeId)
                  .firstOrNull
                  ?.name ??
              modes.currentModeId,
          chevron: busy != modesId,
          trailing: busy == modesId ? const _Busy() : null,
          onTap: busy != null ? null : () => onOpen(modesId),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle(
          session.agentName.isEmpty ? context.l10n.settings : session.agentName,
        ),
        if (rows.isEmpty)
          Text(
            context.l10n.noSessionSettings,
            style: context.typo.sansBody.copyWith(color: colors.muted),
          )
        else
          BayaGroup(children: rows),
        _SignOut(session: session),
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
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${(usage.fraction * 100).toStringAsFixed(1)}%',
              style: context.typo.sansBody.copyWith(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                letterSpacing: -.8,
              ),
            ),
            const Spacer(),
            Text(
              context.l10n.tokensOf(_count(usage.used), _count(usage.size)),
              style: context.typo.monoSmall.copyWith(
                fontSize: 12,
                color: colors.muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: usage.fraction,
            minHeight: 6,
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

/// The title row inside the settings sheet, which changes as it navigates.
class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title, {this.onBack, this.busy = false});

  final String title;
  final VoidCallback? onBack;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            if (onBack != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: IconButton(
                  tooltip: context.l10n.back,
                  visualDensity: VisualDensity.compact,
                  onPressed: onBack,
                  icon: const Icon(LucideIcons.chevronLeft, size: 20),
                ),
              ),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typo.sansBody.copyWith(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.3,
                ),
              ),
            ),
            if (busy) const _Busy(),
          ],
        ),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 8, right: 8),
    child: SizedBox.square(
      dimension: 14,
      child: CircularProgressIndicator(
        strokeWidth: 1.5,
        color: context.colors.muted,
      ),
    ),
  );
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
    // Choices the agent groups (models by provider, say) get one card each.
    final groups = <(String?, List<_Choice>)>[];
    for (final choice in choices) {
      if (groups.isEmpty || groups.last.$1 != choice.group) {
        groups.add((choice.group, []));
      }
      groups.last.$2.add(choice);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetTitle(title, onBack: onBack, busy: busy),
        for (var i = 0; i < groups.length; i++) ...[
          if (groups[i].$1 case final label?)
            BayaSectionLabel(label, top: i == 0 ? 0 : 14)
          else if (i > 0)
            const SizedBox(height: 12),
          BayaGroup(
            children: [
              for (final choice in groups[i].$2)
                BayaRow(
                  key: ValueKey('choice-${choice.id}'),
                  label: choice.label,
                  subtitle: choice.detail,
                  selected: choice.selected,
                  onTap: busy || choice.selected
                      ? null
                      : () => onPick(choice.id),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Signs the session's agent out on the computer, for agents that support
/// ACP `logout`.
class _SignOut extends StatefulWidget {
  const _SignOut({required this.session});
  final SessionController session;

  @override
  State<_SignOut> createState() => _SignOutState();
}

class _SignOutState extends State<_SignOut> {
  late final Future<bool> _supported = widget.session.authMethods().then(
    (result) => result.$2,
    onError: (_) => false,
  );
  bool _busy = false;

  Future<void> _signOut(String agent) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => BayaDialog(
        title: Text(context.l10n.signOutOf(agent)),
        content: Text(
          context.l10n.signOutBody,
          style: TextStyle(color: colors.muted2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            key: const Key('sign-out-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              context.l10n.signOut,
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.session.logout();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      await showBayaNotice(
        context,
        title: context.l10n.signOutFailed,
        message: '$error',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.session.agentName.isEmpty
        ? context.l10n.yourAgent
        : widget.session.agentName;
    return FutureBuilder(
      future: _supported,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: BayaGroup(
            children: [
              BayaRow(
                key: const Key('sign-out'),
                icon: LucideIcons.logOut,
                label: context.l10n.signOutOf(agent),
                destructive: true,
                trailing: _busy ? const _Busy() : null,
                onTap: _busy ? null : () => _signOut(agent),
              ),
            ],
          ),
        );
      },
    );
  }
}
