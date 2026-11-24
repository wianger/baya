/// The workspace overview shown when no chat is open.
library;

import 'package:app/data/launcher/launcher.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/runs/run_page.dart';
import 'package:app/ui/workspaces/session_actions.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/widgets/session_row.dart';
import 'package:app/ui/workspaces/workspace_navigation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class SessionWelcome extends StatelessWidget {
  const SessionWelcome({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.watch<HomeViewModel>();
    final state = vm.state;
    final menu = SessionShell.menuOf(context);
    return Scaffold(
      backgroundColor: colors.bg,
      // DeepSeek's home: no title bar, a floating menu circle on the left
      // and the new-chat action in a floating capsule on the right.
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(72),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                if (menu != null)
                  BayaSurface(
                    role: BayaSurfaceRole.floating,
                    radius: 26,
                    child: SizedBox.square(
                      dimension: 52,
                      child: IconButton(
                        key: const Key('overview-menu'),
                        onPressed: menu,
                        tooltip: context.l10n.openNavigation,
                        icon: Icon(
                          LucideIcons.textAlignStart,
                          size: 21,
                          color: colors.text,
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                if (vm.selectedWorkspace != null)
                  BayaSurface(
                    role: BayaSurfaceRole.floating,
                    radius: 26,
                    child: SizedBox.square(
                      dimension: 52,
                      child: IconButton(
                        key: const Key('overview-new-chat'),
                        onPressed: () => openNewSession(context),
                        tooltip: context.l10n.newSession,
                        icon: Icon(
                          LucideIcons.messageCirclePlus,
                          size: 21,
                          color: colors.text,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: switch (state) {
          HomeLoading() => const Center(child: CircularProgressIndicator()),
          HomeNoPeer() => const _NoDeviceOverview(),
          HomeList() => _WorkspaceOverview(vm: vm),
        },
      ),
    );
  }
}

class _NoDeviceOverview extends StatelessWidget {
  const _NoDeviceOverview();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: BayaSurface(
            radius: 32,
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: colors.selection,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      LucideIcons.monitorSmartphone,
                      color: colors.accent,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    context.l10n.bringFirstComputerOnline,
                    textAlign: TextAlign.center,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    context.l10n.pairDeviceHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.muted2,
                      fontSize: 14,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 24),
                  BayaButton(
                    onPressed: () => context.push('/pair'),
                    icon: const Icon(LucideIcons.scanLine, size: 18),
                    label: Text(context.l10n.pairComputer),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceOverview extends StatelessWidget {
  const _WorkspaceOverview({required this.vm});

  final HomeViewModel vm;

  static const _recentShown = 6;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final workspace = vm.selectedWorkspace;
    final items = [...vm.workspaceItems]
      ..sort(
        (a, b) => (b.session.updatedAt ?? DateTime(0)).compareTo(
          a.session.updatedAt ?? DateTime(0),
        ),
      );
    bool working(HomeItem item) =>
        vm.isRoomWorking(item.peer.remoteEpk, item.sessionId);
    final running = items.where(working).toList();
    final pinned = vm.pinnedFirst(
      items.where((item) => !working(item) && vm.isPinned(item)),
    );
    final recent = items
        .where((item) => !working(item) && !vm.isPinned(item))
        .toList();
    final folders = items
        .map((item) => item.session.cwd)
        .where((folder) => folder.isNotEmpty)
        .toSet()
        .length;
    final deviceEpk = vm.selectedDevice;
    final runs = context
        .watch<Preferences>()
        .runs
        .where(
          (run) =>
              deviceEpk != null &&
              toStandardB64(run.hostId) == toStandardB64(deviceEpk) &&
              (workspace == null ||
                  run.workspaceKey == null ||
                  run.workspaceKey == workspace),
        )
        .toList(growable: false);
    final device = deviceEpk == null ? null : vm.devices[deviceEpk];
    final online = deviceEpk != null && vm.isRoomLive(deviceEpk, '');
    final deviceName =
        device?.nickname ?? device?.name ?? context.l10n.noDeviceSelected;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const Key('workspace-overview'),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
          children: [
            // DeepSeek's empty state: the mark, then a greeting, centred.
            const SizedBox(height: 12),
            const Center(child: AppMark(size: 40)),
            const SizedBox(height: 14),
            Text(
              vm.workspaceLabel(workspace) ?? context.l10n.noWorkspace,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: context.typo.greeting,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: online ? colors.success : colors.muted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    [
                      deviceName,
                      online
                          ? context.l10n.statusReady
                          : context.l10n.statusOffline,
                      if (folders > 0) context.l10n.folderCount(folders),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 14,
                      color: colors.muted2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            BayaReveal(child: _StartCard(enabled: online && workspace != null)),
            if (running.isNotEmpty) ...[
              BayaSectionLabel(context.l10n.runningNow, top: 26),
              BayaReveal(
                delay: BayaReveal.stagger(1),
                child: _SessionRows(vm: vm, items: running),
              ),
            ],
            if (pinned.isNotEmpty) ...[
              BayaSectionLabel(context.l10n.pinned, top: 26),
              BayaReveal(
                delay: BayaReveal.stagger(1),
                child: _SessionRows(vm: vm, items: pinned),
              ),
            ],
            if (runs.isNotEmpty) ...[
              BayaSectionLabel(context.l10n.parallelRuns, top: 26),
              BayaReveal(
                delay: BayaReveal.stagger(2),
                child: RunRows(
                  runs: runs.take(3).toList(growable: false),
                  onOpen: (run) => openRun(context, run.id),
                ),
              ),
            ],
            // With every other session pinned, Recent has nothing to say.
            if (recent.isNotEmpty || pinned.isEmpty) ...[
              BayaSectionLabel(context.l10n.recent, top: 26),
              if (items.isEmpty)
                _EmptyWorkspaceCard(hasWorkspace: workspace != null)
              else if (recent.isEmpty)
                Text(
                  context.l10n.allSessionsRunning,
                  style: context.typo.sansBody.copyWith(color: colors.muted),
                )
              else
                _SessionRows(
                  vm: vm,
                  items: recent.take(_recentShown).toList(),
                  more: recent.length > _recentShown ? recent : null,
                ),
            ],
            // Conversations the agents had outside Baya, to continue here.
            if (online) ...[
              const SizedBox(height: 14),
              BayaGroup(
                children: [
                  BayaRow(
                    key: const Key('overview-computer-sessions'),
                    icon: LucideIcons.squareTerminal,
                    label: context.l10n.computerSessionsRow,
                    subtitle: context.l10n.computerSessionsRowHint,
                    chevron: true,
                    onTap: () => openComputerSessions(context),
                  ),
                  if (vm.canControlScreen)
                    BayaRow(
                      key: const Key('overview-remote-control'),
                      icon: LucideIcons.monitorSmartphone,
                      label: context.l10n.remoteControl,
                      subtitle: context.l10n.remoteControlHint,
                      chevron: true,
                      onTap: () => openRemoteControl(context),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Where a new conversation starts: looks like the composer it leads to.
class _StartCard extends StatelessWidget {
  const _StartCard({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Text shared from another app waits here for the session it goes to.
    final draft = context.watch<SharedDraft?>();
    final shared = draft?.text;
    return BayaSurface(
      key: const Key('overview-new-session'),
      role: BayaSurfaceRole.floating,
      radius: 28,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? () => openNewSession(context) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (shared == null)
                  Text(
                    context.l10n.whatShouldAgentDo,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 16,
                      color: colors.muted,
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          shared,
                          key: const Key('overview-shared-text'),
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 15,
                            height: 1.4,
                            color: colors.text,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.discardShared,
                        visualDensity: VisualDensity.compact,
                        onPressed: draft!.clear,
                        icon: Icon(
                          LucideIcons.x,
                          size: 18,
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Icon(
                      shared == null
                          ? LucideIcons.folderOpen
                          : LucideIcons.share,
                      size: 16,
                      color: colors.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        shared == null
                            ? context.l10n.pickFolderAndAgent
                            : context.l10n.sharedTextHint,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 13,
                          color: colors.muted,
                        ),
                      ),
                    ),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: enabled ? colors.text : colors.inputFill,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        LucideIcons.arrowUp,
                        size: 18,
                        color: enabled ? colors.bg : colors.muted,
                      ),
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

/// Sessions as one grouped card; [more] adds a "Show all" row.
class _SessionRows extends StatelessWidget {
  const _SessionRows({required this.vm, required this.items, this.more});

  final HomeViewModel vm;
  final List<HomeItem> items;
  final List<HomeItem>? more;

  @override
  Widget build(BuildContext context) {
    return BayaGroup(
      children: [
        for (final item in items)
          SessionRow(
            key: ValueKey('overview-session-${item.sessionId}'),
            vm: vm,
            item: item,
          ),
        if (more case final all?)
          BayaRow(
            key: const Key('overview-previous-sessions'),
            icon: LucideIcons.history,
            label: context.l10n.showAllSessions(all.length),
            chevron: true,
            onTap: () => showPreviousSessions(context, all),
          ),
      ],
    );
  }
}

class _EmptyWorkspaceCard extends StatelessWidget {
  const _EmptyWorkspaceCard({required this.hasWorkspace});

  final bool hasWorkspace;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Icon(
            hasWorkspace
                ? LucideIcons.messageSquareDashed
                : LucideIcons.layoutDashboard,
            color: colors.muted,
            size: 20,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasWorkspace
                      ? context.l10n.noSessionsYet
                      : context.l10n.noWorkspaceSelected,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasWorkspace
                      ? context.l10n.startOneAbove
                      : context.l10n.useSidebarToChooseWorkspace,
                  style: context.typo.sansBody.copyWith(
                    color: colors.muted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
