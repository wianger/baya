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
import 'package:app/ui/workspaces/session_sheet.dart';
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
    await vm.openSession(item.peer.remoteEpk, item.sessionId);
    if (!context.mounted) return;
    final device = item.peer.label;
    final online = vm.isRoomLive(item.peer.remoteEpk, item.sessionId);
    final displayName = vm.displayNameOf(item);
    context.read<SessionSelection>().select(
      item.peer.remoteEpk,
      item.sessionId,
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

/// The session sheet for a row in the session list.
Future<void> showSessionActions(BuildContext context, HomeItem item) {
  final vm = context.read<HomeViewModel>();
  final selection = context.read<SessionSelection>();
  return showSessionSheet(
    context,
    title: vm.displayNameOf(item),
    agent: item.session.agentName,
    computer: item.peer.label,
    folder: item.session.cwd,
    onRename: () => renameSession(context, item),
    onDelete: () async {
      final wasSelected = selection.matches(
        item.peer.remoteEpk,
        item.sessionId,
      );
      await vm.deleteSession(item);
      if (wasSelected) {
        selection.clear();
        if (context.mounted) context.go('/home');
      }
    },
  );
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
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: BayaSurface(
        key: const Key('new-workspace-sheet'),
        role: BayaSurfaceRole.overlay,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        elevated: false,
        child: StatefulBuilder(
          builder: (sheetContext, setSheetState) => SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: sheetContext.colors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    context.l10n.newWorkspace,
                    style: sheetContext.typo.title.copyWith(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.l10n.workspaceExplainer,
                    style: sheetContext.typo.sansBody.copyWith(
                      color: sheetContext.colors.muted,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: name,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: InputDecoration(
                      hintText: context.l10n.workspaceNameHint,
                    ),
                  ),
                  const SizedBox(height: 16),
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
                    minimumSize: const Size.fromHeight(50),
                  ),
                ],
              ),
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
