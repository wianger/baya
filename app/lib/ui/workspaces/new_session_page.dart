import 'package:app/acp/acp.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/workspaces/states/new_session_state.dart';
import 'package:app/ui/workspaces/viewmodels/new_session_viewmodel.dart';
import 'package:app/ui/workspaces/widgets/agent_picker.dart';
import 'package:app/ui/workspaces/widgets/device_picker.dart';
import 'package:app/ui/workspaces/widgets/workspace_scope_field.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class NewSessionPage extends StatefulWidget {
  const NewSessionPage({super.key});
  @override
  State<NewSessionPage> createState() => _NewSessionPageState();
}

class _NewSessionPageState extends State<NewSessionPage> {
  final _path = TextEditingController();
  String? _lastPath;
  bool _leaving = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _cancel() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    await context.read<NewSessionViewModel>().cancel();
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) context.pop();
  }

  Future<void> _open({String? agentSessionId}) async {
    final result = await context.read<NewSessionViewModel>().open(
      agentSessionId: agentSessionId,
    );
    if (!mounted || result == null) return;
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    context.pop(result);
  }

  Future<void> _openRun() async {
    final run = await context.read<NewSessionViewModel>().openRun();
    if (!mounted || run == null) return;
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    context.pop(run);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<NewSessionViewModel>();
    final state = vm.state;
    final ready = state is NewSessionReady ? state : null;
    if (ready?.directory?.path != _lastPath) {
      _lastPath = ready?.directory?.path;
      _path.text = _lastPath ?? '';
    }
    final colors = context.colors;
    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && ready?.opening != true) _cancel();
      },
      child: Scaffold(
        backgroundColor: colors.bg,
        appBar: AppBar(
          backgroundColor: colors.bg.withValues(alpha: 0),
          flexibleSpace: const BayaSurface(
            role: BayaSurfaceRole.navigation,
            radius: 0,
            elevated: false,
            child: SizedBox.expand(),
          ),
          centerTitle: true,
          leading: IconButton(
            onPressed: ready?.opening == true ? null : _cancel,
            icon: const Icon(LucideIcons.x),
            tooltip: context.l10n.cancel,
          ),
          title: Text(context.l10n.newSession),
          actions: [
            IconButton(
              tooltip: context.l10n.refreshComputers,
              onPressed: ready?.opening == true ? null : vm.load,
              icon: const Icon(LucideIcons.refreshCw, size: 19),
            ),
          ],
        ),
        body: BayaBackdrop(
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: switch (state) {
                  NewSessionLoading() => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  NewSessionUnavailable(:final message) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: BayaSurface(
                        radius: 24,
                        elevated: false,
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(message, textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              OutlinedButton(
                                onPressed: vm.load,
                                child: Text(context.l10n.tryAgain),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  NewSessionReady() => BayaReveal(
                    offset: 7,
                    child: _content(context, state, vm),
                  ),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    NewSessionReady state,
    NewSessionViewModel vm,
  ) {
    final colors = context.colors;
    final directory = state.directory;
    final locked = state.loading || state.opening;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DevicePickerField(
            devices: state.hosts,
            selected: state.host,
            enabled: !locked,
            onChanged: vm.selectHost,
          ),
          const SizedBox(height: 18),
          _WorkspacePickerField(
            workspaces: state.workspacesForHost,
            selected: state.selectedWorkspaceGroup,
            computerLabel: state.host.label,
            enabled: !locked && state.host.online,
            onChanged: (workspace) => vm.setWorkspace(workspace.workspaceKey),
          ),
          const SizedBox(height: 14),
          AgentPickerField(
            agents: directory?.agents ?? const [],
            selected: directory?.agents.isNotEmpty == true ? state.agent : null,
            computerLabel: state.host.label,
            enabled: !locked && state.host.online,
            onChanged: vm.setAgent,
          ),
          if ((directory?.availableAgents.length ?? 0) > 1)
            _AlsoRun(state: state, vm: vm, enabled: !locked),
          const SizedBox(height: 8),
          Text(
            context.l10n.chooseFolderHint,
            style: TextStyle(color: colors.muted2, fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _path,
            enabled: !locked,
            autocorrect: false,
            enableSuggestions: false,
            style: context.typo.mono.copyWith(fontSize: 12),
            decoration: InputDecoration(
              labelText: context.l10n.folderPath,
              hintText: context.l10n.absolutePathHint,
              suffixIcon: IconButton(
                tooltip: context.l10n.goToFolder,
                onPressed: locked ? null : () => vm.browse(path: _path.text),
                icon: const Icon(LucideIcons.arrowRight, size: 18),
              ),
            ),
            onSubmitted: (path) => vm.browse(path: path),
          ),
          Row(
            children: [
              IconButton(
                tooltip: context.l10n.homeFolder,
                onPressed: locked
                    ? null
                    : () => vm.browse(path: directory?.home),
                icon: const Icon(LucideIcons.house, size: 18),
              ),
              IconButton(
                tooltip: context.l10n.parentFolder,
                onPressed: locked || directory?.parent == null
                    ? null
                    : () => vm.browse(path: directory!.parent),
                icon: const Icon(LucideIcons.arrowUp, size: 18),
              ),
              const Spacer(),
              Text(
                context.l10n.hiddenFolders,
                style: TextStyle(color: colors.muted2, fontSize: 12),
              ),
              Switch(
                value: state.showHidden,
                onChanged: locked ? null : (_) => vm.toggleHidden(),
              ),
            ],
          ),
          TextField(
            key: ValueKey(directory?.path),
            enabled: !locked,
            decoration: InputDecoration(
              hintText: context.l10n.filterFolders,
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              isDense: true,
            ),
            onChanged: vm.setQuery,
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              if (state.error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: BayaSurface(
                      role: BayaSurfaceRole.content,
                      radius: 14,
                      elevated: false,
                      emphasized: true,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.circleAlert,
                              size: 18,
                              color: colors.error,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                state.error!,
                                style: TextStyle(
                                  color: colors.error,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('new-session-retry-browse'),
                              onPressed: locked ? null : vm.retryBrowse,
                              child: Text(context.l10n.tryAgain),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(child: header),
              if (state.loading || state.opening)
                const SliverToBoxAdapter(
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (state.visibleFolders.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        state.loading
                            ? context.l10n.readingFolders
                            : directory == null
                            ? context.l10n.selectOnlineComputer
                            : context.l10n.noSubfolders,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.muted),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.builder(
                    itemCount: state.visibleFolders.length,
                    itemBuilder: (context, index) {
                      final folder = state.visibleFolders[index];
                      return ListTile(
                        leading: Icon(
                          LucideIcons.folder,
                          color: colors.muted2,
                          size: 20,
                        ),
                        title: Text(
                          folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.mono.copyWith(fontSize: 13),
                        ),
                        trailing: Icon(
                          LucideIcons.chevronRight,
                          color: colors.muted,
                          size: 16,
                        ),
                        onTap: locked
                            ? null
                            : () => vm.browse(path: folder.path),
                      );
                    },
                  ),
                ),
              if (directory?.truncated == true)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      context.l10n.first300Folders,
                      style: TextStyle(color: colors.muted, fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: BayaButton(
            key: const ValueKey('new-session-open-button'),
            onPressed: !state.canOpen
                ? null
                : state.alsoAgents.isEmpty
                ? _open
                : _openRun,
            icon: Icon(
              state.alsoAgents.isEmpty
                  ? LucideIcons.plus
                  : LucideIcons.columns3,
              size: 18,
            ),
            label: Text(
              state.alsoAgents.isNotEmpty
                  ? (state.opening
                        ? context.l10n.startingAgents(state.runAgents.length)
                        : context.l10n.startAgentsHere(state.runAgents.length))
                  : state.opening
                  ? context.l10n.startingAgent(state.agent.label)
                  : context.l10n.openAgentHere(state.agent.label),
            ),
            minimumSize: const Size.fromHeight(52),
          ),
        ),
        if (state.alsoAgents.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: TextButton.icon(
              key: const ValueKey('new-session-continue'),
              onPressed: state.canOpen ? _continueEarlier : null,
              icon: const Icon(LucideIcons.history, size: 16),
              label: Text(context.l10n.continueEarlier),
            ),
          ),
      ],
    );
  }

  Future<void> _continueEarlier() async {
    final vm = context.read<NewSessionViewModel>();
    final sessions = vm.earlierSessions();
    final id = await showBayaSheet<String>(
      context,
      title: context.l10n.continueEarlier,
      builder: (_) => _EarlierSessions(sessions: sessions),
    );
    if (id != null && mounted) await _open(agentSessionId: id);
  }
}

/// The agent's own past conversations in the folder; picking one continues
/// it in Baya.
class _EarlierSessions extends StatelessWidget {
  const _EarlierSessions({required this.sessions});
  final Future<List<AgentSessionInfo>> sessions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder(
      future: sessions,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snapshot.hasError || snapshot.data!.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              snapshot.hasError
                  ? '${snapshot.error}'
                  : context.l10n.noEarlierConversations,
              style: TextStyle(
                color: snapshot.hasError ? colors.error : colors.muted,
              ),
            ),
          );
        }
        final localizations = MaterialLocalizations.of(context);
        return BayaGroup(
          children: [
            for (final session in snapshot.data!)
              BayaRow(
                key: ValueKey('earlier-${session.sessionId}'),
                icon: LucideIcons.messageSquare,
                label: session.title.isEmpty
                    ? context.l10n.untitledSession
                    : session.title,
                subtitle: session.updatedAt == null
                    ? null
                    : localizations.formatMediumDate(
                        session.updatedAt!.toLocal(),
                      ),
                chevron: true,
                onTap: () => Navigator.of(context).pop(session.sessionId),
              ),
          ],
        );
      },
    );
  }
}

class _WorkspacePickerField extends StatelessWidget {
  const _WorkspacePickerField({
    required this.workspaces,
    required this.selected,
    required this.computerLabel,
    required this.enabled,
    required this.onChanged,
  });

  final List<WorkspaceGroup> workspaces;
  final WorkspaceGroup? selected;
  final String computerLabel;
  final bool enabled;
  final ValueChanged<WorkspaceGroup> onChanged;

  @override
  Widget build(BuildContext context) {
    final active = enabled && workspaces.isNotEmpty;
    return WorkspaceScopeField(
      interactionKey: const ValueKey('new-session-workspace-picker'),
      label: context.l10n.workspace,
      value:
          selected?.label ??
          (active
              ? context.l10n.chooseWorkspace
              : context.l10n.noWorkspacesOnComputer),
      leading: Icon(
        LucideIcons.layoutDashboard,
        size: 20,
        color: context.colors.muted2,
      ),
      enabled: active,
      onTap: () async {
        final choice = await showBayaSheet<WorkspaceGroup>(
          context,
          sheetKey: const ValueKey('new-session-workspace-sheet'),
          title: context.l10n.chooseWorkspaceTitle,
          subtitle: context.l10n.onComputer(computerLabel),
          builder: (sheetContext) => BayaGroup(
            children: [
              for (final workspace in workspaces)
                BayaRow(
                  key: ValueKey(
                    'new-session-workspace-${workspace.workspaceKey}',
                  ),
                  icon: LucideIcons.layoutDashboard,
                  label: workspace.label,
                  subtitle: workspace.subtitle,
                  selected: workspace.workspaceKey == selected?.workspaceKey,
                  onTap: () => Navigator.of(sheetContext).pop(workspace),
                ),
            ],
          ),
        );
        if (!context.mounted || choice == null) return;
        onChanged(choice);
      },
    );
  }
}

/// More agents for the same task: each starts its own session, side by
/// side, in its own worktree unless the user turns that off.
class _AlsoRun extends StatelessWidget {
  const _AlsoRun({
    required this.state,
    required this.vm,
    required this.enabled,
  });

  final NewSessionReady state;
  final NewSessionViewModel vm;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final others = state.directory!.availableAgents
        .where((agent) => agent.id != state.agent.id)
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.alsoRunWith,
            style: context.typo.sansBody.copyWith(
              fontSize: 12,
              color: colors.muted2,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final agent in others)
                FilterChip(
                  key: ValueKey('also-run-${agent.id}'),
                  label: Text(agent.label),
                  selected: state.alsoAgents.any((a) => a.id == agent.id),
                  onSelected: enabled ? (_) => vm.toggleAlsoAgent(agent) : null,
                ),
            ],
          ),
          AnimatedSize(
            duration: BayaMotion.standard,
            curve: BayaMotion.enter,
            alignment: Alignment.topCenter,
            child: state.alsoAgents.isEmpty
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: BayaGroup(
                      children: [
                        BayaRow(
                          key: const Key('separate-worktrees'),
                          icon: LucideIcons.gitBranch,
                          label: l10n.separateWorktrees,
                          subtitle: l10n.separateWorktreesHint,
                          trailing: Switch(
                            value: state.separateWorktrees,
                            onChanged: enabled ? vm.setSeparateWorktrees : null,
                          ),
                          onTap: enabled
                              ? () => vm.setSeparateWorktrees(
                                  !state.separateWorktrees,
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
