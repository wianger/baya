import 'dart:convert';
import 'dart:math';

/// Workspace ids are phone-local logical identities scoped to one device.
///
/// They intentionally contain no filesystem path. A workspace may group
/// sessions from unrelated folders, and a session belongs to exactly one
/// workspace. A session nobody filed is in its folder's workspace, named
/// as herdr names it (its herdr workspace, else its folder): there is no
/// catch-all.

final _workspaceKey = RegExp(r'^([^:]+):workspace:([^:]+)$');

String newLogicalWorkspaceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return 'workspace-${base64UrlEncode(bytes).replaceAll('=', '')}';
}

String workspaceKey(String deviceEpk, String workspaceId) =>
    '$deviceEpk:workspace:$workspaceId';

const _folderPrefix = 'folder-';

/// The workspace of sessions nobody filed whose herdr workspace or folder
/// is called [label].
String folderWorkspaceKey(String deviceEpk, String label) => workspaceKey(
  deviceEpk,
  '$_folderPrefix${base64Url.encode(utf8.encode(label)).replaceAll('=', '')}',
);

/// The name of a [folderWorkspaceKey]; null for any other workspace.
String? folderWorkspaceLabel(String key) {
  final id = workspaceId(key);
  if (id == null || !id.startsWith(_folderPrefix)) return null;
  try {
    return utf8.decode(
      base64Url.decode(base64Url.normalize(id.substring(_folderPrefix.length))),
    );
  } on FormatException {
    return null;
  }
}

bool isWorkspaceKey(String value) => _workspaceKey.hasMatch(value);

String? workspaceDevice(String value) =>
    _workspaceKey.firstMatch(value)?.group(1);

String? workspaceId(String value) => _workspaceKey.firstMatch(value)?.group(2);

bool isWorkspaceKeyForDevice(String value, String deviceEpk) =>
    workspaceDevice(value) == deviceEpk;
