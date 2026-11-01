import 'package:app/ui/core/branding/app_brand.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_dialogs.dart';
import 'package:app/ui/workspaces/widgets/scope_switchers.dart';
import 'package:app/ui/workspaces/workspace_navigation.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

Future<void> _openSession(
  BuildContext context,
  HomeItem item, {
  VoidCallback? close,
}) async {
  final vm = context.read<HomeViewModel>();
  try {
    await vm.openSession(item.peer.remoteEpk, roomId: item.room.roomId);
    if (!context.mounted) return;
    final device = item.peer.nickname ?? item.peer.sessionName;
    final online = vm.isRoomLive(item.peer.remoteEpk, item.room.roomId);
    final displayName = vm.displayNameOf(item);
    context.read<SessionSelection>().select(
      item.peer.remoteEpk,
      item.room.roomId,
      displayName,
      device,
      online,
    );
    close?.call();
    context.go(
      '/chat',
      extra: {'title': displayName, 'device': device, 'online': online},
    );
  } catch (_) {
    if (context.mounted) {
      await showBayaError(
        context,
        message: 'Could not open this session. Try again.',
      );
    }
  }
}

Future<void> _showPreviousSessions(
  BuildContext context,
  List<HomeItem> items,
) async {
  final vm = context.read<HomeViewModel>();
  final workspaceName = vm.workspaceLabel(vm.selectedWorkspace) ?? 'Workspace';
  final selected = await showModalBottomSheet<HomeItem>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BayaGlassSurface(
      role: BayaGlassRole.overlay,
      radius: 34,
      elevated: false,
      child: _PreviousSessionsSheet(
        vm: vm,
        items: items,
        workspaceName: workspaceName,
      ),
    ),
  );
  if (!context.mounted || selected == null) return;
  await _openSession(context, selected);
}

Future<void> _deleteFromPhone(BuildContext context, HomeItem item) async {
  final vm = context.read<HomeViewModel>();
  final selection = context.read<SessionSelection>();
  final wasSelected = selection.matches(item.peer.remoteEpk, item.room.roomId);
  final confirmed = await showSessionDeleteDialog(
    context,
    name: item.displayName,
  );
  if (!context.mounted || !confirmed) return;
  try {
    await vm.deleteSession(item);
    if (!context.mounted) return;
    if (wasSelected) {
      selection.clear();
      context.go('/home');
    }
  } catch (_) {
    if (context.mounted) {
      await showBayaError(
        context,
        message: 'Could not remove this session. Try again.',
      );
    }
  }
}

Future<void> _renameSession(BuildContext context, HomeItem item) async {
  final vm = context.read<HomeViewModel>();
  final name = await showSessionRenameDialog(
    context,
    currentName: vm.displayNameOf(item),
  );
  if (name == null || !context.mounted) return;
  try {
    await vm.renameSession(item, name);
  } catch (_) {
    if (context.mounted) {
      await showBayaError(context, message: 'Could not rename this session.');
    }
  }
}

Future<void> showCreateWorkspace(BuildContext context) async {
  final vm = context.read<HomeViewModel>();
  final device = vm.selectedDevice;
  if (device == null) {
    await showBayaNotice(
      context,
      title: 'No device selected',
      message: 'Pair a computer first, then create a workspace.',
    );
    return;
  }
  final name = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => BayaGlassSurface(
      role: BayaGlassRole.overlay,
      radius: 34,
      elevated: false,
      child: StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              18,
              0,
              18,
              18 + MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('New workspace', style: sheetContext.typo.title),
                const SizedBox(height: 8),
                Text(
                  'A workspace groups sessions from any folders on this computer.',
                  style: sheetContext.typo.sansBody.copyWith(
                    color: sheetContext.colors.muted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: name,
                  autofocus: true,
                  onChanged: (_) => setSheetState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Workspace name',
                    hintText: 'e.g. Client work',
                  ),
                ),
                const SizedBox(height: 18),
                BayaGlassButton(
                  onPressed: name.text.trim().isEmpty
                      ? null
                      : () async {
                          await vm.createWorkspace(
                            name: name.text,
                            deviceEpk: device,
                          );
                          if (sheetContext.mounted) {
                            Navigator.of(sheetContext).pop();
                          }
                        },
                  icon: const Icon(LucideIcons.layoutDashboard, size: 18),
                  label: const Text('Create workspace'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  name.dispose();
}

Future<void> _startSession(BuildContext context, {VoidCallback? close}) async {
  final vm = context.read<HomeViewModel>();
  final workspace = vm.selectedWorkspace;
  if (workspace == null) {
    await showBayaNotice(
      context,
      title: 'No workspace yet',
      message: 'Create a workspace before starting a session.',
    );
    return;
  }
  close?.call();
  await openNewSession(context, workspaceKey: workspace);
}

class SessionShell extends StatefulWidget {
  const SessionShell({super.key, required this.child});
  final Widget child;
  static VoidCallback? menuOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SessionMenu>()?.open;
  @override
  State<SessionShell> createState() => _SessionShellState();
}

class _SessionShellState extends State<SessionShell>
    with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(
      context.read<HomeViewModel>().refreshComputerSessionInventory(
        force: true,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    return _SessionMenu(
      open: wide ? null : () => _scaffold.currentState?.openDrawer(),
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        drawerScrimColor: Colors.black.withValues(alpha: .28),
        drawer: wide
            ? null
            : Drawer(
                width: math.min(352, MediaQuery.sizeOf(context).width - 28),
                backgroundColor: Colors.transparent,
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(28),
                  ),
                ),
                child: SessionSidebar(
                  close: () => _scaffold.currentState?.closeDrawer(),
                ),
              ),
        body: BayaBackdrop(
          child: Row(
            children: [
              if (wide) ...[
                const SizedBox(width: 304, child: SessionSidebar()),
                VerticalDivider(width: 1, color: context.colors.border),
              ],
              Expanded(child: widget.child),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionMenu extends InheritedWidget {
  const _SessionMenu({required this.open, required super.child});
  final VoidCallback? open;
  @override
  bool updateShouldNotify(_SessionMenu oldWidget) => open != oldWidget.open;
}

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
          message: 'Could not save your selection. Try again.',
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
      await _openSession(context, item, close: widget.close);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<bool> _renameDevice(HomeViewModel vm, String epk) async {
    final peer = vm.devices[epk];
    if (peer == null) return false;
    final name = await showDeviceRenameDialog(
      context,
      currentName: peer.nickname ?? peer.sessionName,
    );
    if (!mounted || name == null || name.trim().isEmpty) return false;
    try {
      await vm.renameDevice(epk, name);
      return true;
    } catch (_) {
      if (mounted) {
        await showBayaError(context, message: 'Could not rename this device.');
      }
      return false;
    }
  }

  Future<bool> _deleteDevice(HomeViewModel vm, String epk) async {
    final peer = vm.devices[epk];
    if (peer == null) return false;
    final wasSelected = vm.selectedDevice == epk;
    final confirmed = await showDeviceDeleteDialog(
      context,
      name: peer.nickname ?? peer.sessionName,
    );
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
      await showBayaError(
        context,
        message: 'Could not delete this device. Try again.',
      );
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
          message: 'Could not delete this workspace. Try again.',
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
          message: 'Could not rename this workspace.',
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
    return BayaGlassSurface(
      role: BayaGlassRole.navigation,
      radius: widget.close == null ? 0 : 28,
      elevated: false,
      blurSigma: 34,
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
                                        tooltip: 'Search sessions',
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
                                      entry.value.nickname ??
                                      entry.value.sessionName,
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
                              'Sessions · ${vm.workspaceItems.length}',
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
                                        ? 'Pair a computer to get started.'
                                        : _query.isNotEmpty
                                        ? 'No matching sessions in this workspace.'
                                        : 'No sessions in this workspace yet. '
                                              'Start one in any folder.',
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
                                        item.room.roomId,
                                      ),
                                      online: vm.isRoomLive(
                                        item.peer.remoteEpk,
                                        item.room.roomId,
                                      ),
                                      working: vm.isRoomWorking(
                                        item.peer.remoteEpk,
                                        item.room.roomId,
                                      ),
                                      onTap: _opening
                                          ? null
                                          : () => _open(item),
                                      onRename: () =>
                                          _renameSession(context, item),
                                      onDelete: () =>
                                          _deleteFromPhone(context, item),
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
                      tooltip: 'Settings',
                      icon: LucideIcons.settings2,
                      onPressed: () {
                        widget.close?.call();
                        context.push('/settings');
                      },
                    ),
                    const Spacer(),
                    BayaGlassButton(
                      buttonKey: const Key('sidebar-new-session'),
                      onPressed: vm.selectedWorkspace == null
                          ? null
                          : () => _startSession(context, close: widget.close),
                      icon: const Icon(LucideIcons.plus, size: 18),
                      label: const Text('New session'),
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
    return BayaGlassSurface(
      role: BayaGlassRole.control,
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
              hintText: 'Search sessions',
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
          tooltip: 'Close search',
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
    this.onRename,
    this.onDelete,
  });
  final HomeItem item;
  final String displayName;
  final bool selected, online, working;
  final VoidCallback? onTap;
  final VoidCallback? onRename;
  final Future<void> Function()? onDelete;
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final agentLabel = workspaceAgentLabelForRoom(item.room.name);
    final title = workspaceSessionTitle(displayName);
    final statusColor = working
        ? colors.working
        : online
        ? colors.success
        : colors.muted;
    final listTile = ListTile(
      key: ValueKey('session-row-${item.peer.remoteEpk}-${item.room.roomId}'),
      selected: selected,
      selectedTileColor: colors.selection,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
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
                    working
                        ? 'Working'
                        : online
                        ? 'Ready'
                        : 'Offline',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: statusColor),
                  ),
                ),
              ],
            ),
            if (item.room.cwd case final cwd?)
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
      trailing: onRename == null
          ? null
          : IconButton(
              key: ValueKey(
                'session-rename-${item.peer.remoteEpk}-${item.room.roomId}',
              ),
              tooltip: 'Rename session',
              visualDensity: VisualDensity.compact,
              onPressed: onRename,
              icon: Icon(LucideIcons.pencil, size: 16, color: colors.muted2),
            ),
      onTap: onTap,
    );
    final tile = BayaGlassSurface(
      role: BayaGlassRole.control,
      radius: 22,
      elevated: false,
      emphasized: selected,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: listTile,
      ),
    );
    return BayaReveal(
      offset: 5,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: onDelete == null
            ? tile
            : ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Dismissible(
                  key: ValueKey(
                    'session-delete-${item.peer.remoteEpk}-${item.room.roomId}',
                  ),
                  direction: DismissDirection.endToStart,
                  dismissThresholds: const {DismissDirection.endToStart: .34},
                  background: const _SessionDeleteBackground(),
                  confirmDismiss: (_) async {
                    await onDelete!();
                    // The ViewModel owns the actual removal and the dialog may
                    // be cancelled. Keep the row in place until state changes.
                    return false;
                  },
                  child: tile,
                ),
              ),
      ),
    );
  }
}

class _SessionDeleteBackground extends StatelessWidget {
  const _SessionDeleteBackground();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: colors.error.withValues(alpha: .16),
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.trash2, size: 18, color: colors.error),
              const SizedBox(width: 8),
              Text(
                'Delete',
                style: context.typo.sansBody.copyWith(
                  color: colors.error,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
        flexibleSpace: const BayaGlassSurface(
          role: BayaGlassRole.navigation,
          radius: 0,
          elevated: false,
          child: SizedBox.expand(),
        ),
        centerTitle: true,
        title: const Text('Overview'),
        leading: SessionShell.menuOf(context) == null
            ? null
            : IconButton(
                onPressed: SessionShell.menuOf(context),
                tooltip: 'Open navigation',
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
          child: BayaGlassSurface(
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
                    'Bring your first computer online',
                    textAlign: TextAlign.center,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Pair a device to see its workspaces and activity here. '
                    'Your navigation and session list will appear in the '
                    'sidebar.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.muted2,
                      fontSize: 14,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 24),
                  BayaGlassButton(
                    onPressed: () => context.push('/pair'),
                    icon: const Icon(LucideIcons.scanLine, size: 18),
                    label: const Text('Pair computer'),
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
      ..sort((a, b) => b.room.startedAt.compareTo(a.room.startedAt));
    final working = items
        .where(
          (item) => vm.isRoomWorking(item.peer.remoteEpk, item.room.roomId),
        )
        .toList();
    final liveCount = items
        .where((item) => vm.isRoomLive(item.peer.remoteEpk, item.room.roomId))
        .length;
    final folderCount = items
        .map((item) => item.room.cwd)
        .whereType<String>()
        .where((folder) => folder.isNotEmpty)
        .toSet()
        .length;
    final focus = working.firstOrNull ?? items.firstOrNull;
    final deviceEpk = vm.selectedDevice;
    final device = deviceEpk == null ? null : vm.devices[deviceEpk];
    final deviceName =
        device?.nickname ?? device?.sessionName ?? 'No device selected';
    final workspaceName = vm.workspaceLabel(workspace) ?? 'No workspace';
    final focusWorking =
        focus != null &&
        vm.isRoomWorking(focus.peer.remoteEpk, focus.room.roomId);
    final previousSessions = focus == null
        ? const <HomeItem>[]
        : items
              .where(
                (item) =>
                    item.peer.remoteEpk != focus.peer.remoteEpk ||
                    item.room.roomId != focus.room.roomId,
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
              'CURRENT WORKSPACE',
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
                    '$folderCount ${folderCount == 1 ? 'folder' : 'folders'}',
                    style: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 24),
            BayaGlassSurface(
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
                  focusWorking ? 'Running now' : 'Continue',
                  style: context.typo.sansBody.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const Spacer(),
                if (working.length > 1)
                  Text(
                    '${working.length} running',
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
                agent: workspaceAgentLabelForRoom(focus.room.name),
                working: focusWorking,
                online: vm.isRoomLive(focus.peer.remoteEpk, focus.room.roomId),
                onOpen: () => _openSession(context, focus),
              ),
            if (previousSessions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('overview-previous-sessions'),
                  onPressed: () =>
                      _showPreviousSessions(context, previousSessions),
                  icon: const Icon(LucideIcons.history, size: 17),
                  label: Text(
                    'Previous sessions (${previousSessions.length})',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Use the sidebar for devices, workspaces and the full session list.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviousSessionsSheet extends StatelessWidget {
  const _PreviousSessionsSheet({
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
                      Text('Previous sessions', style: context.typo.title),
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
                  tooltip: 'Close previous sessions',
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
                  item.room.roomId,
                );
                final online = vm.isRoomLive(
                  item.peer.remoteEpk,
                  item.room.roomId,
                );
                final status = working
                    ? 'Working'
                    : online
                    ? 'Ready'
                    : 'Offline';
                final statusColor = working
                    ? colors.working
                    : online
                    ? colors.success
                    : colors.muted;
                return ListTile(
                  key: ValueKey(
                    'previous-session-${item.peer.remoteEpk}-${item.room.roomId}',
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
                    workspaceSessionTitle(vm.displayNameOf(item)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${workspaceAgentLabelForRoom(item.room.name)} · $status'
                    '${item.room.cwd == null ? '' : ' · ${item.room.cwd}'}',
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
    return BayaGlassSurface(
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
                        workspaceSessionTitle(displayName),
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
                            working
                                ? 'Working'
                                : online
                                ? 'Ready'
                                : 'Offline',
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '$agent · ${item.room.cwd ?? item.room.roomId}',
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
    return BayaGlassSurface(
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
                    hasWorkspace ? 'No sessions yet' : 'No workspace selected',
                    style: context.typo.sansBody.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasWorkspace
                        ? 'Use the sidebar to start one in any folder on this computer.'
                        : 'Use the sidebar to choose or create a workspace.',
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
