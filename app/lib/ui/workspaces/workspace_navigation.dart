import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/runs/parallel_run.dart';
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
  final result = await context.push<Object>(
    '/new-session',
    extra: NewSessionLaunch(
      workspaces: home.workspaceGroups,
      selectedWorkspace: initialWorkspace,
    ),
  );
  if (!context.mounted) return null;
  if (result is ParallelRun) {
    await _startRun(context, home, result, initialWorkspace);
    return null;
  }
  if (result is! OpenedWorkspace) return null;
  final workspace = result;
  final selectedWorkspace = workspace.workspaceKey ?? initialWorkspace;
  await home.selectDevice(workspace.hostId);
  if (!context.mounted) return workspace;
  if (selectedWorkspace != null) {
    await home.assignSessionIdToWorkspace(
      workspace.hostId,
      workspace.sessionId,
      selectedWorkspace,
    );
    await home.selectWorkspace(selectedWorkspace);
    if (!context.mounted) return workspace;
  }
  if (!context.mounted) return workspace;
  context.read<SessionSelection>().select(
    workspace.hostId,
    workspace.sessionId,
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

/// Files a run's sessions under its workspace, keeps the run and shows it.
Future<void> _startRun(
  BuildContext context,
  HomeViewModel home,
  ParallelRun run,
  String? initialWorkspace,
) async {
  final prefs = context.read<Preferences>();
  final workspace = run.workspaceKey ?? initialWorkspace;
  await home.selectDevice(run.hostId);
  if (workspace != null) {
    for (final member in run.members) {
      await home.assignSessionIdToWorkspace(
        run.hostId,
        member.sessionId,
        workspace,
      );
    }
    await home.selectWorkspace(workspace);
  }
  await prefs.addRun(run);
  if (context.mounted) openRun(context, run.id, started: run);
}

/// Shows the board of the run [id]; [started] is the run just begun.
void openRun(BuildContext context, String id, {ParallelRun? started}) =>
    context.go(
      Uri(path: '/run', queryParameters: {'id': id}).toString(),
      extra: started,
    );
