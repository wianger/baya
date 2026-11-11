// Renders the streaming thought window to PNG for design review:
//   BAYA_PREVIEW_DIR=<dir> flutter test test/ui/chat/thinking_preview_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fonts.dart';

void main() {
  final output = Platform.environment['BAYA_PREVIEW_DIR'];
  testWidgets('thinking preview', (tester) async {
    tester.view.physicalSize = const Size(412, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await loadAppFonts(tester);
    const thought =
        'The user wants the login redirect fixed. Let me look at where the '
        'redirect happens first. In src/auth/login.ts the router pushes the '
        'next page right after signIn resolves, but the session cookie is set '
        'by a response header that the browser applies a moment later. So the '
        'next page loads without the cookie and the guard sends it back to '
        '/login. Options: wait for session.ready(), or have the guard retry '
        'once. Waiting is simpler and keeps the guard strict. I should also '
        'check whether any other caller relies on the immediate push, and run '
        'the auth tests afterwards to make sure nothing else regresses.';
    final boundary = GlobalKey();
    final light = Platform.environment['BAYA_PREVIEW_THEME'] == 'light';
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? buildLightTheme() : buildDarkTheme(),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ThinkingBlock(text: thought, complete: false),
                  SizedBox(height: 24),
                  ThinkingBlock(text: thought, complete: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/thinking.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }, skip: output == null);
}
