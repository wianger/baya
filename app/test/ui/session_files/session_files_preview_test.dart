import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/domain/contracts/repository.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/session_files/session_files_page.dart';
import 'package:app/ui/session_files/viewmodels/session_files_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fonts.dart';

class _PreviewRepository extends Repository implements ISessionFilesRepository {
  @override
  Future<SessionDirectoryListing> browse({
    String? path,
    bool showHidden = false,
  }) async {
    return SessionDirectoryListing(
      root: r'C:\code\remote_pi',
      path: r'C:\code\remote_pi',
      parent: null,
      entries: [
        SessionFileEntry(
          name: 'lib',
          path: r'C:\code\remote_pi\lib',
          kind: SessionFileKind.directory,
          modifiedAt: DateTime(2026, 11, 1, 3, 18),
        ),
        SessionFileEntry(
          name: 'test',
          path: r'C:\code\remote_pi\test',
          kind: SessionFileKind.directory,
          modifiedAt: DateTime(2026, 11, 1, 3, 16),
        ),
        SessionFileEntry(
          name: 'README.md',
          path: r'C:\code\remote_pi\README.md',
          kind: SessionFileKind.file,
          size: 4820,
          modifiedAt: DateTime(2026, 11, 1, 2, 48),
        ),
        SessionFileEntry(
          name: 'pubspec.yaml',
          path: r'C:\code\remote_pi\pubspec.yaml',
          kind: SessionFileKind.file,
          size: 1248,
          modifiedAt: DateTime(2026, 11, 1, 2, 42),
        ),
        SessionFileEntry(
          name: 'analysis_options.yaml',
          path: r'C:\code\remote_pi\analysis_options.yaml',
          kind: SessionFileKind.file,
          size: 620,
          modifiedAt: DateTime(2026, 10, 31, 22, 10),
        ),
      ],
    );
  }

  @override
  Future<SessionFileContent> read(String path) async {
    return SessionFileContent(
      name: 'README.md',
      path: path,
      size: 4820,
      modifiedAt: DateTime(2026, 11, 1, 2, 48),
      content:
          '# Remote Pi\n\n'
          'A small, fast bridge between your phone and coding agents.\n\n'
          '## Session files\n\n'
          '- Browse the active workspace read-only.\n'
          '- Preview text files and copy their contents.\n'
          '- Keep binary files on the computer.\n',
      binary: false,
      truncated: false,
    );
  }
}

Future<void> _save(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  final output = Platform.environment['BAYA_PREVIEW_DIR'];
  testWidgets('render the session file browser preview', (tester) async {
    final disabledShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = disabledShadows);
    tester.view.physicalSize = const Size(618, 1338);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadAppFonts(tester);
    final vm = SessionFilesViewModel(_PreviewRepository());
    final key = GlobalKey();
    await tester.pumpWidget(
      ChangeNotifierProvider<SessionFilesViewModel>.value(
        value: vm,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          home: RepaintBoundary(
            key: key,
            child: const SizedBox(
              width: 412,
              height: 892,
              child: SessionFilesPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _save(tester, key, '$output/session-files.png');
    await tester.tap(
      find.byKey(const ValueKey(r'session-file-C:\code\remote_pi\README.md')),
    );
    await tester.pumpAndSettle();
    // Markdown shows rendered.
    expect(
      find.textContaining('Preview text files', findRichText: true),
      findsWidgets,
    );
    await _save(tester, key, '$output/session-file-preview.png');
    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
    debugDisableShadows = disabledShadows;
  }, skip: output == null);
}
