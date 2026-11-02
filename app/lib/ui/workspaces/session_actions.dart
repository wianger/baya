/// Session commands shared by the sidebar, overview and chat.
library;

import 'dart:async';

import 'package:app/l10n/l10n.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_dialogs.dart';
import 'package:app/ui/workspaces/session_overview.dart';
import 'package:app/ui/workspaces/workspace_navigation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

Future<void> openSession(
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
      await showBayaError(context, message: context.l10n.couldNotOpenSession);
    }
  }
}

Future<void> showPreviousSessions(
  BuildContext context,
  List<HomeItem> items,
) async {
  final vm = context.read<HomeViewModel>();
  final workspaceName =
      vm.workspaceLabel(vm.selectedWorkspace) ?? context.l10n.workspace;
  final selected = await showModalBottomSheet<HomeItem>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BayaSurface(
      role: BayaSurfaceRole.overlay,
      radius: 34,
      elevated: false,
      child: PreviousSessionsSheet(
        vm: vm,
        items: items,
        workspaceName: workspaceName,
      ),
    ),
  );
  if (!context.mounted || selected == null) return;
  await openSession(context, selected);
}

Future<void> deleteFromPhone(BuildContext context, HomeItem item) async {
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
      await showBayaError(context, message: context.l10n.couldNotRemoveSession);
    }
  }
}

Future<void> renameSession(BuildContext context, HomeItem item) async {
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
      await showBayaError(context, message: context.l10n.couldNotRenameSession);
    }
  }
}

Future<void> showCreateWorkspace(BuildContext context) async {
  final vm = context.read<HomeViewModel>();
  final device = vm.selectedDevice;
  if (device == null) {
    await showBayaNotice(
      context,
      title: context.l10n.noDeviceSelected,
      message: context.l10n.pairBeforeWorkspace,
    );
    return;
  }
  final name = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => BayaSurface(
      role: BayaSurfaceRole.overlay,
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
                Text(context.l10n.newWorkspace, style: sheetContext.typo.title),
                const SizedBox(height: 8),
                Text(
                  context.l10n.workspaceExplainer,
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
                  decoration: InputDecoration(
                    labelText: context.l10n.workspaceName,
                    hintText: context.l10n.workspaceNameHint,
                  ),
                ),
                const SizedBox(height: 18),
                BayaButton(
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
                  label: Text(context.l10n.createWorkspace),
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

Future<void> startSession(BuildContext context, {VoidCallback? close}) async {
  final vm = context.read<HomeViewModel>();
  final workspace = vm.selectedWorkspace;
  if (workspace == null) {
    await showBayaNotice(
      context,
      title: context.l10n.noWorkspaceYet,
      message: context.l10n.createWorkspaceFirst,
    );
    return;
  }
  close?.call();
  await openNewSession(context, workspaceKey: workspace);
}
