import 'package:app/domain/contracts/repository.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/ui/session_files/session_files_page.dart';
import 'package:app/ui/session_files/viewmodels/session_files_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Repository extends Repository implements ISessionFilesRepository {
  @override
  Future<SessionDirectoryListing> browse({
    String? path,
    bool showHidden = false,
  }) async {
    return const SessionDirectoryListing(
      root: '/project',
      path: '/project',
      parent: null,
      entries: [
        SessionFileEntry(
          name: 'lib',
          path: '/project/lib',
          kind: SessionFileKind.directory,
        ),
        SessionFileEntry(
          name: 'README.md',
          path: '/project/README.md',
          kind: SessionFileKind.file,
          size: 14,
        ),
      ],
    );
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
  testWidgets('browses session entries and opens a text file', (tester) async {
    final vm = SessionFilesViewModel(_Repository());
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<SessionFilesViewModel>.value(
          value: vm,
          child: const SessionFilesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('lib'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.byTooltip('Show hidden files'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('session-file-/project/README.md')),
    );
    await tester.pumpAndSettle();

    // Markdown opens rendered; its source is one tap away, highlighted
    // with line numbers and a copy button.
    expect(find.text('Remote Pi'), findsOneWidget);
    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-file-content')), findsOneWidget);
    expect(find.byKey(const Key('code-copy')), findsOneWidget);
    expect(find.byTooltip('Back to directory'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    vm.dispose();
  });
}
