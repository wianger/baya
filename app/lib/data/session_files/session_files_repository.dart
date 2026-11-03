import 'package:app/data/hosts/hosts.dart';
import 'package:app/domain/contracts/repository.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/routing/adaptive.dart';

/// Read-only files below the selected session's folder (`_baya/files`,
/// `_baya/read_file`).
class SessionFilesRepository extends Repository
    implements ISessionFilesRepository {
  SessionFilesRepository(this._hosts, this._selection);

  final Hosts _hosts;
  final SessionSelection _selection;

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params,
  ) async {
    final selected = _selection.current;
    final host = _hosts.byKey(selected?.hostKey);
    if (selected == null || host == null || !host.isOnline) {
      throw const SessionFilesFailure(
        'This session is offline. Reconnect to the computer and try again.',
      );
    }
    try {
      return await host.call(method, {
        'sessionId': selected.sessionId,
        ...params,
      });
    } catch (error) {
      throw SessionFilesFailure('$error');
    }
  }

  @override
  Future<SessionDirectoryListing> browse({
    String? path,
    bool showHidden = false,
  }) async {
    final data = await _call('_baya/files', {
      'path': ?path,
      'showHidden': showHidden,
    });
    return SessionDirectoryListing(
      root: data['root'] as String,
      path: data['path'] as String,
      parent: data['parent'] as String?,
      entries: [
        for (final entry
            in (data['entries'] as List).cast<Map<String, dynamic>>())
          SessionFileEntry(
            name: entry['name'] as String,
            path: entry['path'] as String,
            kind: entry['type'] == 'directory'
                ? SessionFileKind.directory
                : SessionFileKind.file,
            size: (entry['size'] as num?)?.toInt(),
            modifiedAt: _timestamp(entry['modifiedAt']),
          ),
      ],
      truncated: data['truncated'] == true,
    );
  }

  @override
  Future<SessionFileContent> read(String path) async {
    final data = await _call('_baya/read_file', {'path': path});
    return SessionFileContent(
      name: data['name'] as String,
      path: data['path'] as String,
      size: (data['size'] as num).toInt(),
      modifiedAt: _timestamp(data['modifiedAt']),
      content: data['content'] as String?,
      binary: data['binary'] == true,
      truncated: data['truncated'] == true,
    );
  }

  DateTime? _timestamp(Object? raw) {
    final milliseconds = (raw as num?)?.toInt();
    return milliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
}
