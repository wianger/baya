import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/session_files/states/session_files_state.dart';

class SessionFilesViewModel extends ViewModel<SessionFilesState> {
  SessionFilesViewModel(this._repository) : super(const SessionFilesLoading());

  final ISessionFilesRepository _repository;
  int _generation = 0;
  bool _disposed = false;
  bool _loaded = false;
  bool _showHidden = false;
  SessionDirectoryListing? _lastDirectory;

  bool get showHidden => _showHidden;

  Future<void> load({String? path}) async {
    if (_loaded && path == null && _lastDirectory != null) return;
    await browse(path: path);
  }

  Future<void> browse({String? path}) async {
    final generation = ++_generation;
    emit(SessionFilesLoading(previous: _lastDirectory));
    try {
      final directory = await _repository.browse(
        path: path,
        showHidden: _showHidden,
      );
      if (_disposed || generation != _generation) return;
      _lastDirectory = directory;
      _loaded = true;
      emit(SessionFilesDirectory(directory));
    } catch (error) {
      if (_disposed || generation != _generation) return;
      emit(
        SessionFilesError(
          error is SessionFilesFailure
              ? error.message
              : appL10n.couldNotReadSessionDirectory,
          previous: _lastDirectory,
        ),
      );
    }
  }

  Future<void> refresh() async {
    final current = state;
    final path = switch (current) {
      SessionFilesDirectory(:final directory) => directory.path,
      SessionFilesFile(:final directory) => directory.path,
      SessionFilesError(:final previous) => previous?.path,
      SessionFilesLoading(:final previous) => previous?.path,
    };
    if (path != null) {
      await browse(path: path);
    } else {
      await browse();
    }
  }

  Future<void> openFile(SessionFileEntry entry) async {
    if (entry.kind != SessionFileKind.file || _lastDirectory == null) return;
    final generation = ++_generation;
    emit(SessionFilesLoading(previous: _lastDirectory));
    try {
      final file = await _repository.read(entry.path);
      if (_disposed || generation != _generation) return;
      emit(SessionFilesFile(file: file, directory: _lastDirectory!));
    } catch (error) {
      if (_disposed || generation != _generation) return;
      emit(
        SessionFilesError(
          error is SessionFilesFailure
              ? error.message
              : appL10n.couldNotReadFile,
          previous: _lastDirectory,
        ),
      );
    }
  }

  void closeFile() {
    final current = state;
    if (current is SessionFilesFile) {
      ++_generation;
      emit(SessionFilesDirectory(current.directory));
    }
  }

  Future<void> toggleHidden() async {
    _showHidden = !_showHidden;
    final current = state;
    final path = switch (current) {
      SessionFilesDirectory(:final directory) => directory.path,
      SessionFilesFile(:final directory) => directory.path,
      SessionFilesError(:final previous) => previous?.path,
      SessionFilesLoading(:final previous) => previous?.path,
    };
    await browse(path: path);
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
