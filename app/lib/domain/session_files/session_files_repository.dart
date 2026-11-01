import 'package:app/domain/contracts/repository.dart';

enum SessionFileKind { file, directory }

class SessionFileEntry {
  const SessionFileEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.size,
    this.modifiedAt,
  });

  final String name;
  final String path;
  final SessionFileKind kind;
  final int? size;
  final DateTime? modifiedAt;
}

class SessionDirectoryListing {
  const SessionDirectoryListing({
    required this.root,
    required this.path,
    required this.parent,
    required this.entries,
    this.truncated = false,
  });

  final String root;
  final String path;
  final String? parent;
  final List<SessionFileEntry> entries;
  final bool truncated;
}

class SessionFileContent {
  const SessionFileContent({
    required this.name,
    required this.path,
    required this.size,
    required this.modifiedAt,
    required this.content,
    required this.binary,
    required this.truncated,
  });

  final String name;
  final String path;
  final int size;
  final DateTime? modifiedAt;
  final String? content;
  final bool binary;
  final bool truncated;
}

class SessionFilesFailure implements Exception {
  const SessionFilesFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract class ISessionFilesRepository extends Repository {
  Future<SessionDirectoryListing> browse({
    String? path,
    bool showHidden = false,
  });

  Future<SessionFileContent> read(String path);
}
