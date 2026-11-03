/// The session sidebar: device and workspace switchers, search, and the
/// session list.
library;

import 'dart:async';

import 'package:app/l10n/l10n.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_actions.dart';
import 'package:app/ui/workspaces/session_dialogs.dart';
import 'package:app/ui/workspaces/widgets/scope_switchers.dart';
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
  String _query = '';
  bool _opening = false;
  bool _choosing = false;
  bool _searching = false;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Claude-style header: search is a single circle until tapped, then the
  /// text field takes the header row.
  void _openSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _search.clear();
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  Future<void> _choose(Future<void> Function() action) async {
    if (_choosing) return;
    setState(() => _choosing = true);
    try {
      await action();
      if (!mounted) return;
      _search.clear();
      setState(() => _query = '');
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
    final query = _query.trim().toLowerCase();
    final items = vm.workspaceItems
        .where((item) => vm.displayNameOf(item).toLowerCase().contains(query))
        .toList();
    return BayaSurface(
      role: BayaSurfaceRole.card,
      radius: widget.close == null ? 0 : 28,
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
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 12, 16),
                            child: _searching
                                ? _SidebarSearchField(
                                    controller: _search,
                                    focusNode: _searchFocus,
                                    onChanged: (value) =>
                                        setState(() => _query = value),
                                    onClose: _closeSearch,
                                  )
                                : Row(
                                    children: [
                                      const AppMark(size: 34, tile: true),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          kAppName,
                                          style: brandDisplayTextStyle(
                                            fontSize: 31,
                                            color: colors.text,
                                          ),
                                        ),
                                      ),
                                      _SidebarCircleAction(
                                        key: const Key('sidebar-search'),
                                        tooltip: context.l10n.searchSessions,
                                        icon: LucideIcons.search,
                                        onPressed: _openSearch,
                                      ),
                                    ],
                                  ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                            child: Text(
                              context.l10n.sessionsCount(
                                vm.workspaceItems.length,
                              ),
                              style: TextStyle(
                                color: colors.muted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (items.isEmpty)
                            SizedBox(
                              height: 200,
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Center(
                                  child: Text(
                                    state is HomeNoPeer
                                        ? context.l10n.pairToGetStarted
                                        : _query.isNotEmpty
                                        ? context.l10n.noMatchingSessions
                                        : context.l10n.noSessionsInWorkspace,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: colors.muted,
                                      height: 1.6,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Column(
                                children: [
                                  for (final item in items)
                                    _SessionRow(
                                      item: item,
                                      displayName: vm.displayNameOf(item),
                                      selected: selection.matches(
                                        item.peer.remoteEpk,
                                        item.sessionId,
                                      ),
                                      online: vm.isRoomLive(
                                        item.peer.remoteEpk,
                                        item.sessionId,
                                      ),
                                      working: vm.isRoomWorking(
                                        item.peer.remoteEpk,
                                        item.sessionId,
                                      ),
                                      onTap: _opening
                                          ? null
                                          : () => _open(item),
                                      onMore: () =>
                                          showSessionActions(context, item),
                                    ),
                                ],
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
                    _SidebarCircleAction(
                      key: const Key('sidebar-settings'),
                      tooltip: context.l10n.settings,
                      icon: LucideIcons.settings2,
                      onPressed: () {
                        widget.close?.call();
                        context.push('/settings');
                      },
                    ),
                    const Spacer(),
                    BayaButton(
                      buttonKey: const Key('sidebar-new-session'),
                      onPressed: vm.selectedWorkspace == null
                          ? null
                          : () => startSession(context, close: widget.close),
                      icon: const Icon(LucideIcons.plus, size: 18),
                      label: Text(context.l10n.newSession),
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

class _SidebarCircleAction extends StatelessWidget {
  const _SidebarCircleAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaSurface(
      role: BayaSurfaceRole.control,
      radius: 22,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: SizedBox.square(
          dimension: 48,
          child: IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            icon: Icon(icon, size: 22, color: colors.muted2),
          ),
        ),
      ),
    );
  }
}

/// Header search that replaces the brand row once the search button is tapped.
class _SidebarSearchField extends StatelessWidget {
  const _SidebarSearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('sidebar-search-field'),
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged,
            style: context.typo.sansBody.copyWith(fontSize: 15),
            decoration: InputDecoration(
              hintText: context.l10n.searchSessions,
              isDense: true,
              filled: true,
              fillColor: colors.glassFill,
              prefixIcon: Icon(
                LucideIcons.search,
                size: 18,
                color: colors.muted,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const Key('sidebar-search-close'),
          tooltip: context.l10n.closeSearch,
          onPressed: onClose,
          icon: Icon(LucideIcons.x, size: 19, color: colors.muted2),
        ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.item,
    required this.displayName,
    required this.selected,
    required this.online,
    required this.working,
    this.onTap,
    this.onMore,
  });
  final HomeItem item;
  final String displayName;
  final bool selected, online, working;
  final VoidCallback? onTap;
  final VoidCallback? onMore;
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final agentLabel = item.session.agentName;
    final title = displayName;
    final statusColor = working
        ? colors.working
        : online
        ? colors.success
        : colors.muted;
    final listTile = ListTile(
      key: ValueKey('session-row-${item.peer.remoteEpk}-${item.sessionId}'),
      selected: selected,
      selectedTileColor: colors.selection,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      leading: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Icon(
          selected ? LucideIcons.messagesSquare : LucideIcons.messageSquare,
          size: 19,
          color: selected ? colors.accent : colors.muted2,
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 15,
          color: colors.text,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  agentLabel,
                  style: TextStyle(fontSize: 11, color: colors.muted2),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    context.l10n.sessionStatus(
                      working: working,
                      online: online,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: statusColor),
                  ),
                ),
              ],
            ),
            if (item.session.cwd case final cwd when cwd.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.monoSmall.copyWith(
                    fontSize: 10,
                    color: colors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
      trailing: onMore == null
          ? null
          : IconButton(
              key: ValueKey(
                'session-more-${item.peer.remoteEpk}-${item.sessionId}',
              ),
              tooltip: context.l10n.sessionActions,
              visualDensity: VisualDensity.compact,
              onPressed: onMore,
              icon: Icon(LucideIcons.ellipsis, size: 18, color: colors.muted),
            ),
      onTap: onTap,
    );
    final tile = Material(
      color: selected ? colors.selection : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: listTile,
    );
    return BayaReveal(
      offset: 5,
      child: Padding(padding: const EdgeInsets.only(bottom: 2), child: tile),
    );
  }
}
