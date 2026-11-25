/// The agents' own conversations on a computer, from every folder: started
/// in a terminal, an editor or anywhere but Baya. Picking one continues it
/// here.
library;

import 'package:app/acp/acp.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_dialog.dart';
import 'package:app/ui/core/widgets/baya_group.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/workspaces/widgets/session_row.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What [ComputerSessionsPage] needs to know about the computer.
class ComputerSessionsLaunch {
  const ComputerSessionsLaunch({required this.hostId, required this.label});
  final String hostId;
  final String label;
}

class ComputerSessionsPage extends StatefulWidget {
  const ComputerSessionsPage({
    super.key,
    required this.launch,
    required this.repository,
    this.now,
  });

  final ComputerSessionsLaunch launch;
  final IWorkspaceRepository repository;

  /// The clock, for tests.
  final DateTime Function()? now;

  /// Written to this recently, a conversation may still be open where it
  /// started.
  static const recent = Duration(minutes: 5);

  @override
  State<ComputerSessionsPage> createState() => _ComputerSessionsPageState();
}

class _ComputerSessionsPageState extends State<ComputerSessionsPage> {
  late Future<ComputerSessions> _sessions = _load();
  final _search = TextEditingController();
  String _query = '';
  String? _agent;
  String? _opening;

  Future<ComputerSessions> _load() =>
      widget.repository.computerSessions(widget.launch.hostId);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _active(AgentSessionInfo session) {
    final at = session.updatedAt;
    if (at == null) return false;
    final now = (widget.now ?? DateTime.now)();
    return now.difference(at) < ComputerSessionsPage.recent;
  }

  Future<void> _open(AgentSessionInfo session) async {
    if (_opening != null) return;
    if (_active(session) && !await _confirmActive()) return;
    if (!mounted) return;
    setState(() => _opening = session.sessionId);
    try {
      final opened = await widget.repository.open(
        widget.launch.hostId,
        session.cwd,
        WorkspaceAgent(id: session.agent, label: session.agentName),
        agentSessionId: session.sessionId,
        title: session.title.isEmpty ? null : session.title,
      );
      if (mounted) Navigator.of(context).pop(opened);
    } catch (error) {
      if (!mounted) return;
      setState(() => _opening = null);
      await showBayaError(context, message: '$error');
    }
  }

  Future<bool> _confirmActive() async {
    final l10n = context.l10n;
    final go = await showBayaDialog<bool>(
      context: context,
      builder: (dialogContext) => BayaDialog(
        title: Text(l10n.stillOpenTitle),
        content: Text(
          l10n.stillOpenBody,
          style: TextStyle(color: dialogContext.colors.muted2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('computer-session-continue-anyway'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.continueAnyway),
          ),
        ],
      ),
    );
    return go == true;
  }

  List<AgentSessionInfo> _shown(List<AgentSessionInfo> all) {
    final query = _query.trim().toLowerCase();
    return [
      for (final session in all)
        if ((_agent == null || session.agent == _agent) &&
            (query.isEmpty ||
                session.title.toLowerCase().contains(query) ||
                session.cwd.toLowerCase().contains(query)))
          session,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: BayaHeader(
        title: l10n.computerSessions,
        subtitle: widget.launch.label,
        actions: [
          HeaderAction(
            icon: LucideIcons.refreshCw,
            tooltip: l10n.refresh,
            onPressed: _opening != null
                ? null
                : () => setState(() => _sessions = _load()),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _sessions,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _Waiting(text: l10n.askingAgents);
          }
          if (snapshot.hasError) {
            return _Message(
              icon: LucideIcons.circleAlert,
              text: '${snapshot.error}',
              action: TextButton(
                onPressed: () => setState(() => _sessions = _load()),
                child: Text(l10n.retry),
              ),
            );
          }
          final result = snapshot.data!;
          final all = result.sessions;
          final counts = <String, (String, int)>{};
          for (final session in all) {
            final (name, count) =
                counts[session.agent] ?? (session.agentName, 0);
            counts[session.agent] = (name, count + 1);
          }
          final shown = _shown(all);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                key: const Key('computer-sessions'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  Text(
                    l10n.computerSessionsHint,
                    style: TextStyle(color: colors.muted, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  _SearchField(
                    controller: _search,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  if (counts.length > 1) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _FilterChip(
                            key: const Key('computer-sessions-all'),
                            label: l10n.allAgents(all.length),
                            selected: _agent == null,
                            onTap: () => setState(() => _agent = null),
                          ),
                          for (final MapEntry(key: id, value: (name, count))
                              in counts.entries)
                            _FilterChip(
                              key: ValueKey('computer-sessions-agent-$id'),
                              label: '$name $count',
                              selected: _agent == id,
                              onTap: () => setState(
                                () => _agent = _agent == id ? null : id,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (result.failed.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.agentsCouldNotList(result.failed.join(', ')),
                      style: TextStyle(color: colors.warning, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (shown.isEmpty)
                    _Message(
                      icon: LucideIcons.messageSquareDashed,
                      text: all.isEmpty
                          ? l10n.noComputerSessions
                          : l10n.noMatchingConversations,
                    )
                  else
                    BayaReveal(
                      child: BayaGroup(
                        children: [
                          for (final session in shown.take(120))
                            _SessionTile(
                              session: session,
                              active: _active(session),
                              opening: _opening == session.sessionId,
                              onTap: () => _open(session),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.active,
    required this.opening,
    required this.onTap,
  });

  final AgentSessionInfo session;
  final bool active;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final folder = session.cwd
        .split(RegExp(r'[/\\]'))
        .lastWhere((part) => part.isNotEmpty, orElse: () => session.cwd);
    final when = session.updatedAt;
    return BayaRow(
      key: ValueKey('computer-session-${session.agent}-${session.sessionId}'),
      icon: opening ? LucideIcons.loaderCircle : LucideIcons.messageSquare,
      spinning: opening,
      label: session.title.isEmpty
          ? context.l10n.untitledSession
          : session.title,
      subtitle: [
        session.agentName,
        if (folder.isNotEmpty) folder,
        if (when != null) relativeTime(context, when),
      ].join(' · '),
      trailing: active
          ? Padding(
              padding: const EdgeInsets.only(left: 8, right: 4),
              child: Text(
                context.l10n.activeNow,
                key: const Key('computer-session-active'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.warning,
                ),
              ),
            )
          : null,
      chevron: !active,
      onTap: onTap,
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaSurface(
      role: BayaSurfaceRole.control,
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          Icon(LucideIcons.search, size: 17, color: colors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: const Key('computer-sessions-search'),
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 15, color: colors.text),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: context.l10n.searchComputerSessions,
                hintStyle: TextStyle(color: colors.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? colors.text : colors.surface,
        shape: StadiumBorder(
          side: BorderSide(color: selected ? colors.text : colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: selected ? colors.bg : colors.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 14),
        Text(text, style: TextStyle(color: context.colors.muted)),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 26, color: context.colors.muted),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.colors.muted, height: 1.4),
        ),
        ?action,
      ],
    ),
  );
}
