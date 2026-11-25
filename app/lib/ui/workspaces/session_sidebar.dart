/// The session sidebar: device and workspace switchers, search, and the
/// session list.
library;

import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/runs/run_page.dart';
import 'package:app/ui/workspaces/session_actions.dart';
import 'package:app/ui/workspaces/session_dialogs.dart';
import 'package:app/ui/workspaces/session_search.dart';
import 'package:app/ui/workspaces/widgets/scope_switchers.dart';
import 'package:app/ui/workspaces/widgets/session_list_row.dart';
import 'package:app/ui/workspaces/workspace_navigation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class SessionSidebar extends StatefulWidget {
  const SessionSidebar({super.key, this.close});
  final VoidCallback? close;
  @override
  State<SessionSidebar> createState() => _SessionSidebarState();
}

class _SessionSidebarState extends State<SessionSidebar> {
  /// Sessions listed before "View all".
  static const _recents = 8;

  Widget _entry({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: DrawerLine(key: key, icon: icon, label: label, onTap: onTap),
  );

  bool _opening = false;
  bool _choosing = false;

  /// Claude's search: a card over the drawer; the session picked opens.
  Future<void> _openSearch() async {
    final item = await showSessionSearch(context);
    if (item != null && mounted) await _open(item);
  }

  Future<void> _choose(Future<void> Function() action) async {
    if (_choosing) return;
    setState(() => _choosing = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        await showBayaError(
          context,
          message: context.l10n.couldNotSaveSelection,
        );
      }
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _open(HomeItem item) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await openSession(context, item, close: widget.close);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<bool> _renameDevice(HomeViewModel vm, String epk) async {
    final peer = vm.devices[epk];
    if (peer == null) return false;
    final name = await showDeviceRenameDialog(context, currentName: peer.label);
    if (!mounted || name == null || name.trim().isEmpty) return false;
    try {
      await vm.renameDevice(epk, name);
      return true;
    } catch (_) {
      if (mounted) {
        await showBayaError(
          context,
          message: context.l10n.couldNotRenameDevice,
        );
      }
      return false;
    }
  }

  Future<bool> _deleteDevice(HomeViewModel vm, String epk) async {
    final peer = vm.devices[epk];
    if (peer == null) return false;
    final wasSelected = vm.selectedDevice == epk;
    final confirmed = await showDeviceDeleteDialog(context, name: peer.label);
    if (!mounted || !confirmed) return false;
    try {
      await vm.deleteDevice(epk);
      if (wasSelected && mounted) {
        context.read<SessionSelection>().clear();
        widget.close?.call();
        context.go('/home');
      }
      return true;
    } catch (_) {
      if (!mounted) return false;
      await showBayaError(context, message: context.l10n.couldNotDeleteDevice);
      return false;
    }
  }

  Future<bool> _deleteWorkspace(HomeViewModel vm, String key) async {
    final name = vm.workspaceLabel(key);
    if (name == null) return false;
    final confirmed = await showWorkspaceDeleteDialog(context, name: name);
    if (!mounted || !confirmed) return false;
    try {
      await vm.deleteWorkspace(key);
      return true;
    } catch (_) {
      if (mounted) {
        await showBayaError(
          context,
          message: context.l10n.couldNotDeleteWorkspace,
        );
      }
      return false;
    }
  }

  Future<bool> _renameWorkspace(
    HomeViewModel vm,
    String key,
    String currentName,
  ) async {
    final name = await showWorkspaceRenameDialog(
      context,
      currentName: currentName,
    );
    if (!mounted || name == null || name.trim().isEmpty) return false;
    try {
      await vm.renameWorkspace(key, name);
      return true;
    } catch (_) {
      if (mounted) {
        await showBayaError(
          context,
          message: context.l10n.couldNotRenameWorkspace,
        );
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.watch<HomeViewModel>();
    final state = vm.state;
    final selection = context.watch<SessionSelection>();
    final workspaces = vm.workspaces;
    final deviceEpk = vm.selectedDevice;
    final runs = (context.watch<Preferences?>()?.runs ?? const [])
        .where(
          (run) =>
              deviceEpk != null &&
              toStandardB64(run.hostId) == toStandardB64(deviceEpk) &&
              (vm.selectedWorkspace == null ||
                  run.workspaceKey == null ||
                  run.workspaceKey == vm.selectedWorkspace),
        )
        .toList(growable: false);
    final items = vm.workspaceItems;
    return BayaSurface(
      radius: 0,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: state is HomeLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          // Claude's drawer header: the name on the left,
                          // a round search button on the right.
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
                            child: Row(
                              children: [
                                const AppMark(size: 30),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    kAppName,
                                    style: brandDisplayTextStyle(
                                      fontSize: 34,
                                      color: colors.text,
                                    ),
                                  ),
                                ),
                                BayaCircleButton(
                                  key: const Key('sidebar-search'),
                                  icon: LucideIcons.search,
                                  tooltip: context.l10n.searchSessions,
                                  onPressed: _openSearch,
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: DeviceSwitcher(
                              key: const Key('device-selector'),
                              devices: {
                                for (final entry in vm.devices.entries)
                                  entry.key:
                                      entry.value.nickname ?? entry.value.name,
                              },
                              selected: vm.selectedDevice,
                              enabled: !_choosing,
                              onSelected: (value) =>
                                  _choose(() => vm.selectDevice(value)),
                              onAdd: () {
                                widget.close?.call();
                                context.push('/pair');
                              },
                              onRename: (epk) => _renameDevice(vm, epk),
                              onDelete: (epk) => _deleteDevice(vm, epk),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: WorkspaceSwitcher(
                              key: const Key('workspace-selector'),
                              workspaces: workspaces,
                              labels: {
                                for (final key in workspaces.keys)
                                  key: vm.workspaceLabel(key) ?? key,
                              },
                              selected: vm.selectedWorkspace,
                              hasDevice: vm.selectedDevice != null,
                              enabled: !_choosing,
                              onSelected: (value) =>
                                  _choose(() => vm.selectWorkspace(value)),
                              onCreate: () => showCreateWorkspace(context),
                              onRename: (key, currentName) =>
                                  _renameWorkspace(vm, key, currentName),
                              canDelete: vm.canDeleteWorkspace,
                              onDelete: (key) => _deleteWorkspace(vm, key),
                            ),
                          ),
                          const SizedBox(height: 12),
                          // What the home page no longer lists: the
                          // computer's own conversations, its screen, and
                          // parallel runs.
                          if (vm.selectedHost != null) ...[
                            _entry(
                              key: const Key('drawer-computer-sessions'),
                              icon: LucideIcons.squareTerminal,
                              label: context.l10n.computerSessionsRow,
                              onTap: () {
                                widget.close?.call();
                                unawaited(openComputerSessions(context));
                              },
                            ),
                            if (vm.canControlScreen)
                              _entry(
                                key: const Key('drawer-remote-control'),
                                icon: LucideIcons.monitorSmartphone,
                                label: context.l10n.remoteControl,
                                onTap: () {
                                  widget.close?.call();
                                  unawaited(openRemoteControl(context));
                                },
                              ),
                          ],
                          if (runs.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
                              child: Text(
                                context.l10n.parallelRuns,
                                style: context.typo.sansBody.copyWith(
                                  color: colors.muted,
                                  fontSize: BayaType.subhead,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: RunRows(
                                runs: runs.take(3).toList(growable: false),
                                onOpen: (run) {
                                  widget.close?.call();
                                  openRun(context, run.id);
                                },
                              ),
                            ),
                          ],
                          Padding(
                            padding: const EdgeInsets.fromLTRB(28, 18, 24, 4),
                            child: Text(
                              context.l10n.recents,
                              style: context.typo.sansBody.copyWith(
                                color: colors.muted,
                                fontSize: BayaType.body,
                              ),
                            ),
                          ),
                          if (items.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                28,
                                12,
                                24,
                                24,
                              ),
                              child: Text(
                                state is HomeNoPeer
                                    ? context.l10n.pairToGetStarted
                                    : context.l10n.noSessionsInWorkspace,
                                style: TextStyle(
                                  color: colors.muted,
                                  height: 1.6,
                                  fontSize: BayaType.subhead,
                                ),
                              ),
                            )
                          else ...[
                            for (final item in items.take(_recents))
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: SessionListRow(
                                  key: ValueKey(
                                    'session-row-${item.peer.remoteEpk}-${item.sessionId}',
                                  ),
                                  vm: vm,
                                  item: item,
                                  highlighted: selection.matches(
                                    item.peer.remoteEpk,
                                    item.sessionId,
                                  ),
                                  onOpen: () {
                                    if (!_opening) _open(item);
                                  },
                                  onMore: () =>
                                      showSessionActions(context, item),
                                ),
                              ),
                            if (items.length > _recents)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    12,
                                  ),
                                  child: TextButton(
                                    key: const Key('sidebar-view-all'),
                                    onPressed: _openSearch,
                                    style: TextButton.styleFrom(
                                      foregroundColor: colors.muted,
                                      textStyle: context.typo.sansBody.copyWith(
                                        fontSize: BayaType.body,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(context.l10n.viewAll),
                                        const SizedBox(width: 4),
                                        const Icon(
                                          LucideIcons.chevronRight,
                                          size: 16,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
              ),
              // Footer: settings circle on the left, the primary New session
              // pill bottom-right. No divider above it — the pill itself
              // separates the footer from the session list.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                child: Row(
                  children: [
                    BayaCircleButton(
                      key: const Key('sidebar-settings'),
                      tooltip: context.l10n.settings,
                      icon: LucideIcons.settings2,
                      onPressed: () {
                        widget.close?.call();
                        context.push('/settings');
                      },
                    ),
                    const SizedBox(width: 12),
                    // Takes the rest of the row and keeps the pill at its
                    // right end; the pill shrinks rather than overflows with
                    // large text or a long translation.
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: BayaButton(
                          buttonKey: const Key('sidebar-new-session'),
                          onPressed: vm.selectedWorkspace == null
                              ? null
                              : () =>
                                    startSession(context, close: widget.close),
                          icon: const Icon(LucideIcons.plus, size: 18),
                          label: Text(
                            context.l10n.newSession,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
