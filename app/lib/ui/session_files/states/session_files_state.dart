import 'package:app/domain/session_files/session_files_repository.dart';

sealed class SessionFilesState {
  const SessionFilesState();
}

final class SessionFilesLoading extends SessionFilesState {
  const SessionFilesLoading({this.previous});
  final SessionDirectoryListing? previous;

  @override
  bool operator ==(Object other) =>
      other is SessionFilesLoading && identical(previous, other.previous);

  @override
  int get hashCode => previous.hashCode;
}

final class SessionFilesDirectory extends SessionFilesState {
  const SessionFilesDirectory(this.directory);
  final SessionDirectoryListing directory;

  @override
  bool operator ==(Object other) =>
      other is SessionFilesDirectory && identical(directory, other.directory);

  @override
  int get hashCode => directory.hashCode;
}

final class SessionFilesFile extends SessionFilesState {
  const SessionFilesFile({required this.file, required this.directory});
  final SessionFileContent file;
  final SessionDirectoryListing directory;

  @override
  bool operator ==(Object other) =>
      other is SessionFilesFile &&
      identical(file, other.file) &&
      identical(directory, other.directory);

  @override
  int get hashCode => Object.hash(file, directory);
}

final class SessionFilesError extends SessionFilesState {
  const SessionFilesError(this.message, {this.previous});
  final String message;
  final SessionDirectoryListing? previous;

  @override
  bool operator ==(Object other) =>
      other is SessionFilesError &&
      message == other.message &&
      identical(previous, other.previous);

  @override
  int get hashCode => Object.hash(message, previous);
}
