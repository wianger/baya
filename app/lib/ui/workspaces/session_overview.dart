/// The workspace overview shown when no chat is open.
library;

import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_actions.dart';
import 'package:app/ui/workspaces/session_shell.dart';
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
    final working = items
        .where((item) => vm.isRoomWorking(item.peer.remoteEpk, item.sessionId))
        .toList();
    final liveCount = items
        .where((item) => vm.isRoomLive(item.peer.remoteEpk, item.sessionId))
        .length;
    final folderCount = items
        .map((item) => item.session.cwd)
        .where((folder) => folder.isNotEmpty)
        .toSet()
        .length;
    final focus = working.firstOrNull ?? items.firstOrNull;
    final deviceEpk = vm.selectedDevice;
    final device = deviceEpk == null ? null : vm.devices[deviceEpk];
    final deviceName =
        device?.nickname ?? device?.name ?? context.l10n.noDeviceSelected;
    final workspaceName =
        vm.workspaceLabel(workspace) ?? context.l10n.noWorkspace;
    final focusWorking =
        focus != null &&
        vm.isRoomWorking(focus.peer.remoteEpk, focus.sessionId);
    final previousSessions = focus == null
        ? const <HomeItem>[]
        : items
              .where(
                (item) =>
                    item.peer.remoteEpk != focus.peer.remoteEpk ||
                    item.sessionId != focus.sessionId,
              )
              .toList(growable: false);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          key: const Key('workspace-overview'),
          padding: const EdgeInsets.fromLTRB(24, 30, 24, 32),
          children: [
            Text(
              context.l10n.currentWorkspace,
              style: context.typo.monoSmall.copyWith(
                color: colors.accent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              workspaceName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.typo.sansBody.copyWith(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                height: 1.14,
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(LucideIcons.monitor, size: 16, color: colors.muted2),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    deviceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.muted2,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (folderCount > 0) ...[
                  const SizedBox(width: 8),
                  Text('·', style: TextStyle(color: colors.muted)),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.folderCount(folderCount),
                    style: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 24),
            BayaSurface(
              radius: 26,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Row(
                  children: [
                    Expanded(
                      child: _OverviewMetric(
                        key: const Key('overview-sessions'),
                        label: 'SESSIONS',
                        value: '${items.length}',
                        color: colors.text,
                      ),
                    ),
                    _MetricDivider(color: colors.border),
                    Expanded(
                      child: _OverviewMetric(
                        key: const Key('overview-live'),
                        label: 'LIVE',
                        value: '$liveCount',
                        color: liveCount > 0 ? colors.success : colors.muted2,
                      ),
                    ),
                    _MetricDivider(color: colors.border),
                    Expanded(
                      child: _OverviewMetric(
                        key: const Key('overview-working'),
                        label: 'WORKING',
                        value: '${working.length}',
                        color: working.isNotEmpty
                            ? colors.working
                            : colors.muted2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Text(
                  focusWorking
                      ? context.l10n.runningNow
                      : context.l10n.continueLabel,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const Spacer(),
                if (working.length > 1)
                  Text(
                    context.l10n.runningCount(working.length),
                    style: TextStyle(
                      color: colors.working,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (focus == null)
              _EmptyWorkspaceCard(hasWorkspace: workspace != null)
            else
              _FocusSessionCard(
                item: focus,
                displayName: vm.displayNameOf(focus),
                agent: focus.session.agentName,
                working: focusWorking,
                online: vm.isRoomLive(focus.peer.remoteEpk, focus.sessionId),
                onOpen: () => openSession(context, focus),
              ),
            if (previousSessions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('overview-previous-sessions'),
                  onPressed: () =>
                      showPreviousSessions(context, previousSessions),
                  icon: const Icon(LucideIcons.history, size: 17),
                  label: Text(
                    context.l10n.previousSessionsCount(previousSessions.length),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              context.l10n.useSidebarHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class PreviousSessionsSheet extends StatelessWidget {
  const PreviousSessionsSheet({
    super.key,
    required this.vm,
    required this.items,
    required this.workspaceName,
  });

  final HomeViewModel vm;
  final List<HomeItem> items;
  final String workspaceName;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ConstrainedBox(
      key: const Key('previous-sessions-sheet'),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .68,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.previousSessions,
                        style: context.typo.title,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        workspaceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          color: colors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.closePreviousSessions,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons.x, size: 20),
                ),
              ],
            ),
          ),
          Flexible(
            fit: FlexFit.loose,
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              itemCount: items.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                indent: 56,
                color: colors.border.withValues(alpha: .7),
              ),
              itemBuilder: (context, index) {
                final item = items[index];
                final working = vm.isRoomWorking(
                  item.peer.remoteEpk,
                  item.sessionId,
                );
                final online = vm.isRoomLive(
                  item.peer.remoteEpk,
                  item.sessionId,
                );
                final status = context.l10n.sessionStatus(
                  working: working,
                  online: online,
                );
                final statusColor = working
                    ? colors.working
                    : online
                    ? colors.success
                    : colors.muted;
                return ListTile(
                  key: ValueKey(
                    'previous-session-${item.peer.remoteEpk}-${item.sessionId}',
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: colors.selection,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      working
                          ? LucideIcons.activity
                          : LucideIcons.messageSquare,
                      size: 18,
                      color: working ? colors.working : colors.accent,
                    ),
                  ),
                  title: Text(
                    vm.displayNameOf(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${item.session.agentName} · $status'
                    ' · ${item.session.cwd}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      color: statusColor,
                      fontSize: 11.5,
                    ),
                  ),
                  trailing: Icon(
                    LucideIcons.arrowUpRight,
                    size: 18,
                    color: colors.muted,
                  ),
                  onTap: () => Navigator.of(context).pop(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewMetric extends StatelessWidget {
  const _OverviewMetric({
    super.key,
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: context.typo.sansBody.copyWith(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: context.typo.monoSmall.copyWith(
            color: context.colors.muted,
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 34, color: color);
}

class _FocusSessionCard extends StatelessWidget {
  const _FocusSessionCard({
    required this.item,
    required this.displayName,
    required this.agent,
    required this.working,
    required this.online,
    required this.onOpen,
  });

  final HomeItem item;
  final String displayName;
  final String agent;
  final bool working;
  final bool online;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusColor = working
        ? colors.working
        : online
        ? colors.success
        : colors.muted;
    return BayaSurface(
      radius: 28,
      child: Material(
        color: colors.bg.withValues(alpha: 0),
        child: InkWell(
          key: const Key('overview-focus-session'),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: working
                        ? colors.working.withValues(alpha: .12)
                        : colors.selection,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(
                    working ? LucideIcons.activity : LucideIcons.messageSquare,
                    size: 22,
                    color: working ? colors.working : colors.accent,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            context.l10n.sessionStatus(
                              working: working,
                              online: online,
                            ),
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '$agent · ${item.session.cwd}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.muted,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(LucideIcons.arrowUpRight, size: 19, color: colors.muted2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyWorkspaceCard extends StatelessWidget {
  const _EmptyWorkspaceCard({required this.hasWorkspace});

  final bool hasWorkspace;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaSurface(
      radius: 28,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            Icon(
              hasWorkspace
                  ? LucideIcons.messageSquareDashed
                  : LucideIcons.layoutDashboard,
              color: colors.muted2,
              size: 24,
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
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasWorkspace
                        ? context.l10n.useSidebarToStart
                        : context.l10n.useSidebarToChooseWorkspace,
                    style: TextStyle(
                      color: colors.muted,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
