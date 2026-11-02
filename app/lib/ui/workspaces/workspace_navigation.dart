import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/states/new_session_state.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

Future<OpenedWorkspace?> openNewSession(
  BuildContext context, {
  String? workspaceKey,
}) async {
  final home = context.read<HomeViewModel>();
  final initialWorkspace = workspaceKey ?? home.selectedWorkspace;
  final workspace = await context.push<OpenedWorkspace>(
    '/new-session',
    extra: NewSessionLaunch(
      workspaces: home.workspaceGroups,
      selectedWorkspace: initialWorkspace,
    ),
  );
  if (!context.mounted || workspace == null) return null;
  final selectedWorkspace = workspace.workspaceKey ?? initialWorkspace;
  await home.selectDevice(workspace.hostId);
  if (!context.mounted) return workspace;
  if (selectedWorkspace != null) {
    await home.assignSessionRoomToWorkspace(
      workspace.hostId,
      workspace.roomId,
      selectedWorkspace,
    );
    await home.selectWorkspace(selectedWorkspace);
    if (!context.mounted) return workspace;
  }
  if (!context.mounted) return workspace;
  context.read<SessionSelection>().select(
    workspace.hostId,
    workspace.roomId,
    workspace.name,
    workspace.hostLabel,
    true,
  );
  context.go(
    '/chat',
    extra: {
      'title': workspace.name,
      'device': workspace.hostLabel,
      'online': true,
    },
  );
  return workspace;
}
