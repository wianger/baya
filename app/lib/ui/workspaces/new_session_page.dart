import 'package:app/acp/acp.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
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
              prefixIcon: Icon(LucideIcons.search, size: 18),
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
            onPressed: state.canOpen ? _open : null,
            icon: const Icon(LucideIcons.plus, size: 18),
            label: Text(
              state.opening
                  ? context.l10n.startingAgent(state.agent.label)
                  : context.l10n.openAgentHere(state.agent.label),
            ),
            minimumSize: const Size.fromHeight(52),
          ),
        ),
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
    final id = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _EarlierSessions(sessions: vm.earlierSessions()),
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
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .7,
        ),
        child: BayaSurface(
          role: BayaSurfaceRole.overlay,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
          child: FutureBuilder(
            future: sessions,
            builder: (context, snapshot) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Text(
                    context.l10n.continueEarlier,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (snapshot.connectionState != ConnectionState.done)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (snapshot.hasError || snapshot.data!.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    child: Text(
                      snapshot.hasError
                          ? '${snapshot.error}'
                          : context.l10n.noEarlierConversations,
                      style: TextStyle(
                        color: snapshot.hasError ? colors.error : colors.muted,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final session in snapshot.data!)
                          ListTile(
                            key: ValueKey('earlier-${session.sessionId}'),
                            leading: Icon(
                              LucideIcons.messageSquare,
                              size: 18,
                              color: colors.muted2,
                            ),
                            title: Text(
                              session.title.isEmpty
                                  ? context.l10n.untitledSession
                                  : session.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: session.updatedAt == null
                                ? null
                                : Text(
                                    MaterialLocalizations.of(context)
                                        .formatMediumDate(
                                          session.updatedAt!.toLocal(),
                                        ),
                                    style: TextStyle(
                                      color: colors.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                            onTap: () =>
                                Navigator.of(context).pop(session.sessionId),
                          ),
                      ],
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
        final choice = await showModalBottomSheet<WorkspaceGroup>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: Colors.transparent,
          builder: (_) => BayaSurface(
            role: BayaSurfaceRole.overlay,
            radius: 34,
            elevated: false,
            child: _WorkspacePickerSheet(
              workspaces: workspaces,
              selected: selected,
              computerLabel: computerLabel,
            ),
          ),
        );
        if (!context.mounted || choice == null) return;
        onChanged(choice);
      },
    );
  }
}

class _WorkspacePickerSheet extends StatelessWidget {
  const _WorkspacePickerSheet({
    required this.workspaces,
    required this.selected,
    required this.computerLabel,
  });

  final List<WorkspaceGroup> workspaces;
  final WorkspaceGroup? selected;
  final String computerLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ConstrainedBox(
      key: const ValueKey('new-session-workspace-sheet'),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .68,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.chooseWorkspaceTitle,
                        style: context.typo.title,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.l10n.onComputer(computerLabel),
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
                  tooltip: context.l10n.closeWorkspacePicker,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons.x, size: 20),
                ),
              ],
            ),
          ),
          Flexible(
            fit: FlexFit.loose,
            child: ListView.builder(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              itemCount: workspaces.length,
              itemBuilder: (context, index) {
                final workspace = workspaces[index];
                final isSelected =
                    workspace.workspaceKey == selected?.workspaceKey;
                return ListTile(
                  key: ValueKey(
                    'new-session-workspace-${workspace.workspaceKey}',
                  ),
                  selected: isSelected,
                  selectedTileColor: colors.userBubble,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  leading: Icon(
                    LucideIcons.layoutDashboard,
                    size: 20,
                    color: colors.muted2,
                  ),
                  title: Text(
                    workspace.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  subtitle: workspace.subtitle.isEmpty
                      ? null
                      : Text(
                          workspace.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 12,
                            color: colors.muted,
                          ),
                        ),
                  trailing: isSelected
                      ? Icon(LucideIcons.check, size: 18, color: colors.accent)
                      : null,
                  onTap: () => Navigator.of(context).pop(workspace),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
