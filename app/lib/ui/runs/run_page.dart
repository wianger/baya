import 'dart:async';

import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/runs/parallel_run.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/changes/changes_page.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/widgets/session_row.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// A parallel run: every agent's progress side by side, and one composer
/// that gives them all the same instruction.
class RunPage extends StatefulWidget {
  const RunPage({super.key, required this.runId, this.started});

  final String runId;

  /// The run as it was just started, with the agents that failed to.
  final ParallelRun? started;

  @override
  State<RunPage> createState() => _RunPageState();
}

/// What a member's worktree has changed.
typedef _Stats = ({int files, int added, int removed});

class _RunPageState extends State<RunPage> {
  ParallelRun? _run;
  HostConnection? _host;
  final _controllers = <String, SessionController>{};
  final _working = <String, bool>{};
  final _stats = <String, _Stats>{};
  final _prompt = TextEditingController();

  @override
  void initState() {
    super.initState();
    _run = widget.started ?? context.read<Preferences>().run(widget.runId);
    final run = _run;
    _host = run == null ? null : context.read<Hosts>().byKey(run.hostId);
    final host = _host;
    if (run == null || host == null) return;
    for (final member in run.members) {
      final controller = SessionController(host, member.sessionId);
      _controllers[member.sessionId] = controller;
      controller.addListener(() => _onMemberChanged(member));
      unawaited(_refreshStats(member));
    }
    _prompt.addListener(() => setState(() {}));
  }

  void _onMemberChanged(RunMember member) {
    final controller = _controllers[member.sessionId]!;
    final was = _working[member.sessionId] ?? false;
    _working[member.sessionId] = controller.working;
    // A turn just ended: see what it changed.
    if (was && !controller.working) unawaited(_refreshStats(member));
    if (mounted) setState(() {});
  }

  Future<void> _refreshStats(RunMember member) async {
    if (member.branch == null) return;
    final controller = _controllers[member.sessionId];
    if (controller == null || !controller.online) return;
    try {
      final status = await controller.gitStatus();
      final files = (status['files'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final stats = (
        files: files.length,
        added: files.fold<int>(
          0,
          (n, f) => n + ((f['added'] as num?) ?? 0).toInt(),
        ),
        removed: files.fold<int>(
          0,
          (n, f) => n + ((f['removed'] as num?) ?? 0).toInt(),
        ),
      );
      if (mounted) setState(() => _stats[member.sessionId] = stats);
    } catch (_) {
      // Stats are a nicety; the card works without them.
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _prompt.dispose();
    super.dispose();
  }

  bool get _anyWorking => _controllers.values.any((c) => c.working);
  bool get _online => _host?.isOnline ?? false;

  void _send() {
    final text = _prompt.text.trim();
    if (text.isEmpty || !_online) return;
    for (final controller in _controllers.values) {
      unawaited(controller.prompt(text));
    }
    _prompt.clear();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _stopAll() {
    for (final controller in _controllers.values) {
      if (controller.working) controller.cancel();
    }
  }

  void _openMember(RunMember member) {
    final run = _run!;
    final controller = _controllers[member.sessionId];
    final title = controller?.title.isNotEmpty == true
        ? controller!.title
        : '${member.agentLabel} · ${run.name}';
    context.read<SessionSelection>().select(
      run.hostId,
      member.sessionId,
      title,
      run.hostLabel,
      _online,
    );
    context.go(
      '/chat',
      extra: {'title': title, 'device': run.hostLabel, 'online': _online},
    );
  }

  Future<void> _showRunActions() async {
    final run = _run!;
    final l10n = context.l10n;
    final action = await showBayaSheet<String>(
      context,
      title: l10n.parallelRun,
      subtitle: run.folder,
      builder: (sheetContext) => BayaGroup(
        children: [
          BayaRow(
            key: const Key('run-forget'),
            icon: LucideIcons.listX,
            label: l10n.forgetRun,
            subtitle: l10n.forgetRunHint,
            onTap: () => Navigator.of(sheetContext).pop('forget'),
          ),
          if (run.usesWorktrees)
            BayaRow(
              key: const Key('run-delete'),
              icon: LucideIcons.trash2,
              label: l10n.deleteRunAndWorktrees,
              subtitle: l10n.deleteRunAndWorktreesHint,
              destructive: true,
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      final confirmed = await showBayaDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.deleteRunAndWorktrees),
          content: Text(l10n.deleteRunConfirm(run.members.length)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              key: const Key('run-delete-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                l10n.delete,
                style: TextStyle(color: context.colors.error),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final host = _host;
      if (host != null && host.isOnline) {
        for (final member in run.members) {
          _controllers[member.sessionId]?.cancel();
          await host
              .call('session/delete', {'sessionId': member.sessionId})
              .then((_) {}, onError: (_) {});
          if (member.branch != null) {
            await host
                .call('_baya/worktree_remove', {'path': member.path})
                .then((_) {}, onError: (_) {});
          }
        }
      }
    }
    if (!mounted) return;
    await context.read<Preferences>().removeRun(run.id);
    if (mounted) context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final run = _run;
    if (run == null) {
      return Center(
        child: Text(l10n.runNotFound, style: TextStyle(color: colors.muted)),
      );
    }
    final menu = SessionShell.menuOf(context);
    final working = _controllers.values.where((c) => c.working).length;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(
                children: [
                  if (menu != null)
                    IconButton(
                      tooltip: l10n.sessions,
                      onPressed: menu,
                      icon: Icon(
                        LucideIcons.menu,
                        size: 21,
                        color: colors.text,
                      ),
                    )
                  else
                    const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.runTitle(run.members.length, run.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                        Text.rich(
                          TextSpan(
                            text: [
                              run.hostLabel,
                              run.usesWorktrees
                                  ? l10n.ownWorktrees
                                  : l10n.sharedFolder,
                            ].join(' · '),
                            children: [
                              if (working > 0)
                                TextSpan(
                                  text: ' · ${l10n.agentsWorking(working)}',
                                  style: TextStyle(color: colors.working),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 12,
                            color: colors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('run-actions'),
                    tooltip: l10n.sessionActions,
                    onPressed: _showRunActions,
                    icon: Icon(
                      LucideIcons.ellipsis,
                      size: 21,
                      color: colors.muted2,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 1040
                      ? 3
                      : constraints.maxWidth >= 680
                      ? 2
                      : 1;
                  const gap = 12.0;
                  final width =
                      (constraints.maxWidth - 32 - gap * (columns - 1)) /
                      columns;
                  return ListView(
                    key: const Key('run-board'),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      if (run.failures.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            l10n.someAgentsDidNotStart(run.failures.join('\n')),
                            style: TextStyle(color: colors.error, height: 1.4),
                          ),
                        ),
                      // Cards stack in columns, each as tall as it needs.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var column = 0; column < columns; column++) ...[
                            if (column > 0) const SizedBox(width: gap),
                            SizedBox(
                              width: width,
                              child: Column(
                                children: [
                                  for (final (index, member)
                                      in run.members.indexed)
                                    if (index % columns == column)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: gap,
                                        ),
                                        child: BayaReveal(
                                          delay: BayaReveal.stagger(index),
                                          child: _MemberCard(
                                            key: ValueKey(
                                              'run-member-${member.sessionId}',
                                            ),
                                            member: member,
                                            controller:
                                                _controllers[member.sessionId],
                                            stats: _stats[member.sessionId],
                                            onOpen: () => _openMember(member),
                                          ),
                                        ),
                                      ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
            _RunComposer(
              controller: _prompt,
              agents: run.members.length,
              enabled: _online,
              working: _anyWorking,
              onSend: _send,
              onStop: _stopAll,
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({
    super.key,
    required this.member,
    required this.controller,
    required this.stats,
    required this.onOpen,
  });

  final RunMember member;
  final SessionController? controller;
  final _Stats? stats;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final session = controller;
    final messages = session?.messages ?? const <ChatMessage>[];
    final reply = messages.reversed
        .whereType<AssistantMsg>()
        .where((m) => !m.startup && m.text.trim().isNotEmpty)
        .firstOrNull;
    final tool = messages.reversed.whereType<ToolEvent>().firstOrNull;
    final working = session?.working ?? false;
    final needsYou =
        session?.permission != null || session?.elicitation != null;
    final online = session?.online ?? false;
    final (statusLabel, statusColor) = needsYou
        ? (l10n.needsYou, colors.warning)
        : working
        ? (l10n.statusWorking, colors.working)
        : session?.error != null
        ? (l10n.error, colors.error)
        : online
        ? (l10n.statusReady, colors.success)
        : (l10n.statusOffline, colors.muted);
    return BayaSurface(
      elevated: false,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        member.agentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _Status(
                      label: statusLabel,
                      color: statusColor,
                      spinning: working && !needsYou,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  member.branch ?? member.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.monoSmall.copyWith(color: colors.muted),
                ),
                const SizedBox(height: 10),
                AnimatedSwitcher(
                  duration: BayaMotion.standard,
                  switchInCurve: BayaMotion.enter,
                  child: Text(
                    (reply == null ? null : plainSnippet(reply.text)) ??
                        (messages.isEmpty ? l10n.waitingForTask : '…'),
                    key: ValueKey(reply?.id),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 14,
                      height: 1.42,
                      color: reply == null ? colors.muted : colors.text,
                    ),
                  ),
                ),
                if (working && tool != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(LucideIcons.wrench, size: 13, color: colors.muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tool.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.monoSmall.copyWith(
                            color: colors.muted2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (stats case final s? when s.files > 0)
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '+${s.added} ',
                                style: TextStyle(color: colors.success),
                              ),
                              TextSpan(
                                text: '−${s.removed}',
                                style: TextStyle(color: colors.error),
                              ),
                              TextSpan(text: ' · ${l10n.fileCount(s.files)}'),
                            ],
                          ),
                          style: context.typo.monoSmall.copyWith(
                            color: colors.muted,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    if (session != null && member.branch != null)
                      TextButton.icon(
                        key: ValueKey('run-changes-${member.sessionId}'),
                        onPressed: () => openChanges(context, session),
                        icon: const Icon(
                          LucideIcons.gitCompareArrows,
                          size: 16,
                        ),
                        label: Text(l10n.changes),
                      ),
                    TextButton(
                      key: ValueKey('run-open-${member.sessionId}'),
                      onPressed: onOpen,
                      child: Text(l10n.open),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({
    required this.label,
    required this.color,
    required this.spinning,
  });

  final String label;
  final Color color;
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spinning)
          SizedBox.square(
            dimension: 11,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
          )
        else
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        const SizedBox(width: 6),
        Text(
          label,
          style: context.typo.sansBody.copyWith(fontSize: 12, color: color),
        ),
      ],
    );
  }
}

/// One instruction for every agent of the run.
class _RunComposer extends StatelessWidget {
  const _RunComposer({
    required this.controller,
    required this.agents,
    required this.enabled,
    required this.working,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final int agents;
  final bool enabled;
  final bool working;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final hasText = controller.text.trim().isNotEmpty;
    final stop = working && !hasText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: BayaSurface(
        key: const Key('run-composer'),
        role: BayaSurfaceRole.control,
        radius: 26,
        padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('run-prompt'),
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: l10n.tellAllAgents(agents),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            SizedBox.square(
              dimension: 48,
              child: Center(
                child: AnimatedContainer(
                  duration: BayaMotion.standard,
                  curve: BayaMotion.enter,
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: (hasText || stop) && enabled
                        ? colors.text
                        : colors.inputFill,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    key: const Key('run-send'),
                    tooltip: stop ? l10n.stopAll : l10n.sendToAll,
                    padding: EdgeInsets.zero,
                    onPressed: !enabled
                        ? null
                        : stop
                        ? onStop
                        : hasText
                        ? onSend
                        : null,
                    icon: AnimatedSwitcher(
                      duration: BayaMotion.fast,
                      child: Icon(
                        stop ? LucideIcons.square : LucideIcons.arrowUp,
                        key: ValueKey(stop),
                        size: 18,
                        color: (hasText || stop) && enabled
                            ? colors.bg
                            : colors.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The phone's parallel runs on `hostId`, for the overview.
class RunRows extends StatelessWidget {
  const RunRows({super.key, required this.runs, required this.onOpen});

  final List<ParallelRun> runs;
  final ValueChanged<ParallelRun> onOpen;

  @override
  Widget build(BuildContext context) {
    return BayaGroup(
      children: [
        for (final run in runs)
          BayaRow(
            key: ValueKey('overview-run-${run.id}'),
            icon: LucideIcons.columns3,
            label: run.name,
            subtitle: [
              run.members.map((m) => m.agentLabel).join(', '),
              relativeTime(context, run.createdAt),
            ].join(' · '),
            chevron: true,
            onTap: () => onOpen(run),
          ),
      ],
    );
  }
}

/// [markdown] as one line of plain text for a preview: no emphasis marks,
/// headings, list bullets, links' targets or code fences.
String plainSnippet(String markdown) => markdown
    .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
    .replaceAllMapped(
      RegExp(r'!?\[([^\]]*)\]\([^)]*\)'),
      (m) => m.group(1) ?? '',
    )
    .replaceAll(
      RegExp(r'^\s{0,3}(#{1,6}|[-*+]|\d+\.|>)\s+', multiLine: true),
      '',
    )
    .replaceAll(RegExp(r'(\*\*|__|\*|_|~~|`)'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
