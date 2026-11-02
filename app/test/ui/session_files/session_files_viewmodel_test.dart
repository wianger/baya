import 'package:app/domain/contracts/repository.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/ui/session_files/states/session_files_state.dart';
import 'package:app/ui/session_files/viewmodels/session_files_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repository extends Repository implements ISessionFilesRepository {
  int browseCalls = 0;
  String? lastPath;
  bool lastShowHidden = false;
  SessionFilesFailure? browseFailure;

  final listing = const SessionDirectoryListing(
    root: '/project',
    path: '/project',
    parent: null,
    entries: [
      SessionFileEntry(
        name: 'README.md',
        path: '/project/README.md',
        kind: SessionFileKind.file,
        size: 14,
      ),
    ],
  );

  @override
  Future<SessionDirectoryListing> browse({
    String? path,
    bool showHidden = false,
  }) async {
    browseCalls++;
    lastPath = path;
    lastShowHidden = showHidden;
    if (browseFailure case final failure?) throw failure;
    return listing;
  }

  @override
  Future<SessionFileContent> read(String path) async {
    return SessionFileContent(
      name: 'README.md',
      path: path,
      size: 14,
      modifiedAt: DateTime(2026, 11, 1),
      content: '# Remote Pi\n',
      binary: false,
      truncated: false,
    );
  }
}

void main() {
  test('loads, opens and closes a text file', () async {
    final repository = _Repository();
    final vm = SessionFilesViewModel(repository);

    await vm.load();
    expect(vm.state, isA<SessionFilesDirectory>());
    final directory = vm.state as SessionFilesDirectory;
    expect(directory.directory.entries.single.name, 'README.md');

    await vm.openFile(directory.directory.entries.single);
    expect(vm.state, isA<SessionFilesFile>());
    expect((vm.state as SessionFilesFile).file.content, '# Remote Pi\n');

    vm.closeFile();
    expect(vm.state, isA<SessionFilesDirectory>());
    vm.dispose();
  });

  test('hidden toggle refreshes the same directory', () async {
    final repository = _Repository();
    final vm = SessionFilesViewModel(repository);
    await vm.load();

    await vm.toggleHidden();

    expect(repository.lastShowHidden, isTrue);
    expect(repository.lastPath, '/project');
    expect(vm.showHidden, isTrue);
    vm.dispose();
  });

  test('browse failures produce a retryable state', () async {
    final repository = _Repository()
      ..browseFailure = const SessionFilesFailure('Directory unavailable.');
    final vm = SessionFilesViewModel(repository);

    await vm.load();

    expect(
      vm.state,
      isA<SessionFilesError>().having(
        (state) => state.message,
        'message',
        'Directory unavailable.',
      ),
    );
    vm.dispose();
  });
}
