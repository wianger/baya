// Runs the real app on a device or emulator:
//   flutter test integration_test
import 'dart:convert';
import 'dart:io';

import 'package:app/data/preview/pdf_document.dart';
import 'package:app/main.dart' as app;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a fresh install starts at onboarding and moves on', (tester) async {
    app.main();
    for (var i = 0; i < 100 && find.text('Get started').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Get started'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Get started'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android renders a PDF page for the Files page', (tester) async {
    final file = File('${Directory.systemTemp.path}/baya-test.pdf');
    await file.writeAsBytes(_onePagePdf());
    final document = await PdfDocument.open(file.path);
    expect(document.pageSizes, [const Size(200, 100)]);
    final png = await document.render(0, 400);
    expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    await document.close();
  });
}

/// A valid one-page PDF, 200×100 points, with its cross-reference table.
List<int> _onePagePdf() {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(utf8.encode(out.toString()).length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = utf8.encode(out.toString()).length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return utf8.encode(out.toString());
}
