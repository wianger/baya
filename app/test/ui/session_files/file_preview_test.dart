import 'dart:convert';
import 'dart:io';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/ui/session_files/file_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A 1×1 PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// Real file I/O and the fake clock take turns until the preview settles.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
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
    expect(previewKindFor('notes.docx'), isNull);
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
    var fail = true;
    Future<Json> call(String method, Json params) async {
      expect(method, '_baya/download');
      if (fail) throw Exception('offline');
      final bytes = base64Decode(_png);
      return {
        'name': 'shot.png',
        'size': bytes.length,
        'offset': 0,
        'data': _png,
        'eof': true,
      };
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilePreview(
            path: '/w/shot.png',
            name: 'shot.png',
            kind: PreviewKind.image,
            transfer: FileTransfer(call),
            folder: () async => folder,
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.text("Couldn't show this file"), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Try again'));
    await settle(tester);
    expect(find.byKey(const ValueKey('file-preview-image')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });
}
