import 'dart:convert';
import 'dart:io';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/ui/session_files/file_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_transfer.dart';

// A 1×1 PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// Real file I/O and the fake clock take turns until the preview settles.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
}

void main() {
  test('images and PDFs preview, other files do not', () {
    expect(previewKindFor('shot.PNG'), PreviewKind.image);
    expect(previewKindFor('photo.jpeg'), PreviewKind.image);
    expect(previewKindFor('paper.pdf'), PreviewKind.pdf);
    expect(previewKindFor('notes.docx'), PreviewKind.office);
    expect(previewKindFor('logo.svg'), PreviewKind.svg);
    expect(previewKindFor('clip.MOV'), PreviewKind.video);
    expect(previewKindFor('memo.m4a'), PreviewKind.audio);
    expect(previewKindFor('analysis.ipynb'), PreviewKind.notebook);
    expect(previewKindFor('dist.tar.gz'), PreviewKind.archive);
    expect(previewKindFor('app.zip'), PreviewKind.archive);
    expect(previewKindFor('data.csv'), isNull);
    expect(delimiterFor('data.csv'), ',');
    expect(delimiterFor('data.tsv'), '\t');
    expect(previewKindFor('Makefile'), isNull);
  });

  testWidgets('an image comes over, then shows; a failure can be retried', (
    tester,
  ) async {
    final folder = Directory.systemTemp.createTempSync('baya-preview');
    addTearDown(() {
      try {
        folder.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may still hold the image open; the temp folder can wait.
      }
    });
    // Not on the computer yet: the first try fails.
    final computer = FakeComputer();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilePreview(
            path: '/w/shot.png',
            name: 'shot.png',
            kind: PreviewKind.image,
            transfer: FileTransfer(computer),
            folder: () async => folder,
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.text("Couldn't show this file"), findsOneWidget);

    computer.files['/w/shot.png'] = base64Decode(_png);
    await tester.tap(find.text('Try again'));
    await settle(tester);
    debugPrint(
      'SHOWN ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()} ${tester.takeException()}',
    );
    expect(find.byKey(const ValueKey('file-preview-image')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  test('CSV fields may hold quotes, commas and line breaks', () {
    expect(
      parseDelimited(
        'name,note\r\n"Ada, L.","said ""hi""\nthen left"\nBob,',
        ',',
      ),
      [
        ['name', 'note'],
        ['Ada, L.', 'said "hi"\nthen left'],
        ['Bob', ''],
      ],
    );
  });

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('a notebook shows its markdown, code and output', (tester) async {
    final folder = Directory.systemTemp.createTempSync('baya-nb');
    addTearDown(() {
      try {
        folder.deleteSync(recursive: true);
      } on FileSystemException {
        // Still held open on Windows.
      }
    });
    final notebook = utf8.encode(
      jsonEncode({
        'cells': [
          {
            'cell_type': 'markdown',
            'source': ['# Results'],
          },
          {
            'cell_type': 'code',
            'execution_count': 3,
            'source': ['print(1 + 1)'],
            'outputs': [
              {
                'output_type': 'stream',
                'text': ['2\n'],
              },
            ],
          },
        ],
      }),
    );
    final computer = FakeComputer()..files['/w/a.ipynb'] = notebook;
    await tester.pumpWidget(
      host(
        FilePreview(
          path: '/w/a.ipynb',
          name: 'a.ipynb',
          kind: PreviewKind.notebook,
          transfer: FileTransfer(computer),
          folder: () async => folder,
        ),
      ),
    );
    await settle(tester);
    debugPrint(
      'TEXTS: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()} ${find.byType(CircularProgressIndicator).evaluate().length}',
    );
    expect(find.textContaining('Results', findRichText: true), findsWidgets);
    expect(find.text('In [3]'), findsOneWidget);
    expect(find.text('2\n'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('an archive lists its files and opens the one tapped', (
    tester,
  ) async {
    final calls = <String>[];
    Future<Json> call(String method, Json params) async {
      calls.add(method);
      if (method == '_baya/archive_list') {
        return {
          'entries': [
            {'name': 'src/', 'size': 0, 'directory': true},
            {'name': 'src/main.ts', 'size': 2048, 'directory': false},
          ],
          'truncated': false,
        };
      }
      expect(params['entry'], 'src/main.ts');
      return {'path': '/w/.baya/extracted/x/src/main.ts', 'name': 'main.ts'};
    }

    String? opened;
    await tester.pumpWidget(
      host(
        FilePreview(
          path: '/w/app.zip',
          name: 'app.zip',
          kind: PreviewKind.archive,
          transfer: FileTransfer(FakeComputer()..other = call),
          onOpenPath: (path, name) => opened = path,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('main.ts'), findsOneWidget);
    expect(find.text('1 file · tap one to open it'), findsOneWidget);
    await tester.tap(find.text('main.ts'));
    await tester.pumpAndSettle();
    expect(opened, '/w/.baya/extracted/x/src/main.ts');
  });

  testWidgets('an office file says when the computer lacks LibreOffice', (
    tester,
  ) async {
    Future<Json> call(String method, Json params) async {
      expect(method, '_baya/convert_pdf');
      throw const RpcError(-32000, 'no', {'reason': 'no_office'});
    }

    await tester.pumpWidget(
      host(
        FilePreview(
          path: '/w/plan.docx',
          name: 'plan.docx',
          kind: PreviewKind.office,
          transfer: FileTransfer(FakeComputer()..other = call),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Install LibreOffice on the computer to preview office documents here.',
      ),
      findsOneWidget,
    );
  });
}
