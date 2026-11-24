import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/runs/parallel_run.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/terminals/terminals_page.dart';
import 'package:app/ui/workspaces/computer_sessions_page.dart';
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
  if (!context.mounted) return result;
  await _show(context, home, result, initialWorkspace);
  return result;
}

/// The conversations the computer's agents had outside Baya; the one
/// picked opens as a session in the current workspace.
Future<void> openComputerSessions(BuildContext context) async {
  final home = context.read<HomeViewModel>();
  final hostId = home.selectedDevice;
  if (hostId == null) return;
  final initialWorkspace = home.selectedWorkspace;
  final result = await context.push<Object>(
    '/computer-sessions',
    extra: ComputerSessionsLaunch(
      hostId: hostId,
      label: home.devices[hostId]?.label ?? '',
    ),
  );
  if (result is! OpenedWorkspace || !context.mounted) return;
  await _show(context, home, result, initialWorkspace);
}

/// The selected computer's herdr-core terminals.
Future<void> openTerminals(BuildContext context) async {
  final home = context.read<HomeViewModel>();
  final hostId = home.selectedDevice;
  if (hostId == null) return;
  await context.push<void>(
    '/terminals',
    extra: TerminalsLaunch(
      hostId: hostId,
      label: home.devices[hostId]?.label ?? '',
    ),
  );
}

/// Files [workspace]'s new session and shows it.
Future<void> _show(
  BuildContext context,
  HomeViewModel home,
  OpenedWorkspace workspace,
  String? initialWorkspace,
) async {
  final selectedWorkspace = workspace.workspaceKey ?? initialWorkspace;
  await home.selectDevice(workspace.hostId);
  if (!context.mounted) return;
  if (selectedWorkspace != null) {
    await home.assignSessionIdToWorkspace(
      workspace.hostId,
      workspace.sessionId,
      selectedWorkspace,
    );
    await home.selectWorkspace(selectedWorkspace);
    if (!context.mounted) return;
  }
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
}

/// Opens [sessionId], a branch of [fromSessionId] on the same computer, in
/// the same workspace.
Future<void> openBranch(
  BuildContext context,
  String hostId,
  String fromSessionId,
  String sessionId,
) async {
  final home = context.read<HomeViewModel>();
  final selection = context.read<SessionSelection>();
  final current = selection.current;
  final workspace = context.read<Preferences>().workspaceForSession(
    hostId,
    fromSessionId,
  );
  if (workspace != null) {
    await home.assignSessionIdToWorkspace(hostId, sessionId, workspace);
  }
  if (!context.mounted) return;
  final title = current?.title ?? '';
  final device = current?.device ?? '';
  selection.select(hostId, sessionId, title, device, true);
  context.go(
    '/chat',
    extra: {'title': title, 'device': device, 'online': true},
  );
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
