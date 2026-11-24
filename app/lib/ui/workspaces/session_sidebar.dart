/// The session sidebar: device and workspace switchers, search, and the
/// session list.
library;

import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_actions.dart';
import 'package:app/ui/workspaces/session_dialogs.dart';
import 'package:app/ui/workspaces/widgets/scope_switchers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
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
    final items = vm.pinnedFirst(
      vm.workspaceItems.where(
        (item) => vm.displayNameOf(item).toLowerCase().contains(query),
      ),
    );
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
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                            child: _searching
                                ? _SidebarSearchField(
                                    controller: _search,
                                    focusNode: _searchFocus,
                                    onChanged: (value) =>
                                        setState(() => _query = value),
                                    onClose: _closeSearch,
                                  )
                                // DeepSeek's drawer opens on a floating
                                // search capsule.
                                : BayaSurface(
                                    role: BayaSurfaceRole.floating,
                                    radius: 26,
                                    child: InkWell(
                                      key: const Key('sidebar-search'),
                                      onTap: _openSearch,
                                      child: SizedBox(
                                        height: 52,
                                        child: Row(
                                          children: [
                                            const SizedBox(width: 18),
                                            Icon(
                                              LucideIcons.search,
                                              size: 20,
                                              color: colors.muted,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                context.l10n.searchSessions,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: context.typo.sansBody
                                                    .copyWith(
                                                      fontSize: 16,
                                                      color: colors.muted,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
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
                            padding: const EdgeInsets.symmetric(horizontal: 8),
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
                          else
                            for (final (label, group) in _byDay(
                              context,
                              vm,
                              items,
                            )) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  18,
                                  24,
                                  4,
                                ),
                                child: Text(
                                  label,
                                  style: context.typo.sansBody.copyWith(
                                    color: colors.muted,
                                    fontSize: 14,
                                    height: 25 / 14,
                                  ),
                                ),
                              ),
                              for (final item in group)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: _DrawerRow(
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
                            ],
                        ],
                      ),
              ),
              // Footer: DeepSeek's account row, here the way to settings.
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const Key('sidebar-settings'),
                    onTap: () {
                      widget.close?.call();
                      context.push('/settings');
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: colors.inputFill,
                              shape: BoxShape.circle,
                            ),
                            child: const AppMark(size: 26),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              context.l10n.settings,
                              style: context.typo.sansBody.copyWith(
                                fontSize: 16,
                                color: colors.text,
                              ),
                            ),
                          ),
                          Icon(
                            LucideIcons.ellipsis,
                            size: 20,
                            color: colors.muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

/// The sessions under DeepSeek's history headings: pinned first, then today,
/// yesterday, the last 7 and 30 days, then by month.
List<(String, List<HomeItem>)> _byDay(
  BuildContext context,
  HomeViewModel vm,
  List<HomeItem> items,
) {
  final l10n = context.l10n;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final groups = <String, List<HomeItem>>{};
  for (final item in items) {
    final String label;
    final at = item.session.updatedAt?.toLocal();
    if (vm.isPinned(item)) {
      label = l10n.pinned;
    } else if (at == null) {
      label = l10n.historyEarlier;
    } else {
      final day = DateTime(at.year, at.month, at.day);
      final days = today.difference(day).inDays;
      label = days <= 0
          ? l10n.historyToday
          : days == 1
          ? l10n.historyYesterday
          : days < 7
          ? l10n.historyWeek
          : days < 30
          ? l10n.historyMonth
          : DateFormat.yMMMM(Localizations.localeOf(context).toLanguageTag())
                .format(at);
    }
    (groups[label] ??= []).add(item);
  }
  return [for (final MapEntry(:key, :value) in groups.entries) (key, value)];
}

/// One session in the drawer, as DeepSeek lists a chat: its title on one
/// line, the open one filled; a spinner while it works, a dot for news.
class _DrawerRow extends StatelessWidget {
  const _DrawerRow({
    super.key,
    required this.vm,
    required this.item,
    required this.highlighted,
    required this.onOpen,
    required this.onMore,
  });

  final HomeViewModel vm;
  final HomeItem item;
  final bool highlighted;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final working = vm.isRoomWorking(item.peer.remoteEpk, item.sessionId);
    final unread =
        !working &&
        (context.watch<Preferences?>()?.isUnread(
              item.peer.remoteEpk,
              item.session,
            ) ??
            false);
    return Material(
      color: highlighted ? colors.inputFill : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        onLongPress: () {
          unawaited(HapticFeedback.mediumImpact());
          onMore();
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 50),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    vm.displayNameOf(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 16,
                      height: 24 / 16,
                      color: colors.text,
                      fontWeight: highlighted
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (working)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.4,
                        color: colors.muted,
                      ),
                    ),
                  )
                else if (unread)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Container(
                      key: const Key('session-unread'),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: colors.text,
                        shape: BoxShape.circle,
                      ),
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
