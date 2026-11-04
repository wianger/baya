/// The workspace overview shown when no chat is open.
library;

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/runs/run_page.dart';
import 'package:app/ui/workspaces/session_actions.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/workspace_navigation.dart';
import 'package:app/ui/workspaces/widgets/session_row.dart';
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
    return Scaffold(
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
        title: Text(context.l10n.overview),
        leading: SessionShell.menuOf(context) == null
            ? null
            : IconButton(
                onPressed: SessionShell.menuOf(context),
                tooltip: context.l10n.openNavigation,
                icon: const Icon(LucideIcons.panelLeft, size: 21),
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
    final recent = items.where((item) => !working(item)).toList();
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
            Text(
              vm.workspaceLabel(workspace) ?? context.l10n.noWorkspace,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.typo.sansBody.copyWith(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                height: 1.12,
                letterSpacing: -0.9,
              ),
            ),
            const SizedBox(height: 8),
            Row(
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
    return BayaSurface(
      key: const Key('overview-new-session'),
      role: BayaSurfaceRole.control,
      radius: 22,
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
                Text(
                  context.l10n.whatShouldAgentDo,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 16,
                    color: colors.muted,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Icon(LucideIcons.folderOpen, size: 16, color: colors.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.l10n.pickFolderAndAgent,
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
