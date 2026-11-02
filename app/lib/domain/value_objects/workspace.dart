import 'dart:convert';
import 'dart:math';

/// Workspace ids are phone-local logical identities scoped to one device.
///
/// They intentionally contain no filesystem path. A workspace may group
/// sessions from unrelated folders, and a session belongs to exactly one
/// workspace.
const inboxWorkspaceId = 'inbox';

final _workspaceKey = RegExp(r'^([^:]+):workspace:([^:]+)$');

String newLogicalWorkspaceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return 'workspace-${base64UrlEncode(bytes).replaceAll('=', '')}';
}

String workspaceKey(String deviceEpk, String workspaceId) =>
    '$deviceEpk:workspace:$workspaceId';

String inboxWorkspaceKey(String deviceEpk) =>
    workspaceKey(deviceEpk, inboxWorkspaceId);

bool isWorkspaceKey(String value) => _workspaceKey.hasMatch(value);

String? workspaceDevice(String value) =>
    _workspaceKey.firstMatch(value)?.group(1);

String? workspaceId(String value) => _workspaceKey.firstMatch(value)?.group(2);

bool isWorkspaceKeyForDevice(String value, String deviceEpk) =>
    workspaceDevice(value) == deviceEpk;

bool isInboxWorkspace(String value) => workspaceId(value) == inboxWorkspaceId;
