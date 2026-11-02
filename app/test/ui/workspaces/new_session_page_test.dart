import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/workspaces/new_session_page.dart';
import 'package:app/ui/workspaces/states/new_session_state.dart';
import 'package:app/ui/workspaces/viewmodels/new_session_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'new_session_viewmodel_test.dart'
    show FakeWorkspaces, defaultLaunch, directory;

void main() {
  testWidgets(
    'folder chooser works on phone and remains usable with the keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previews = Platform.environment['REMOTE_PI_PREVIEW_DIR'];
      if (previews != null && Platform.isWindows) {
        final font = File(r'C:\Windows\Fonts\segoeui.ttf');
        if (font.existsSync()) {
          final loader = FontLoader('Roboto')
            ..addFont(
              Future.value(ByteData.sublistView(font.readAsBytesSync())),
            );
          await tester.runAsync(loader.load);
        }
      }
      final vm = NewSessionViewModel(FakeWorkspaces(), launch: defaultLaunch);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: vm,
          child: MaterialApp(
            theme: buildDarkTheme(),
            home: RepaintBoundary(
              key: boundaryKey,
              child: const NewSessionPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open Pi here'), findsOneWidget);
      expect(find.text('Device'), findsOneWidget);
      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('new-session-workspace-picker')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose Workspace'), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey('new-session-workspace-computer:workspace:secondary'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Secondary'), findsOneWidget);
      final path = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Folder path',
      );
      await tester.tap(find.text('project'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(path).controller!.text, '/project');
      await tester.tap(find.byTooltip('Parent folder'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(path).controller!.text, '/');
      await tester.tap(find.byTooltip('Home folder'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(path).controller!.text, '/home');
      await tester.tap(find.byKey(const ValueKey('workspace-agent-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-option-codex')));
      await tester.pumpAndSettle();
      expect(find.text('Open Codex here'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (previews != null) {
        await tester.runAsync(() async {
          final image =
              await (boundaryKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(previews).create(recursive: true);
          await File('$previews/folder-phone.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      tester.view.physicalSize = const Size(390, 430);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Open Codex here'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      vm.dispose();
    },
  );

  testWidgets('a failed device switch exposes a targeted retry', (
    tester,
  ) async {
    final repo = FakeWorkspaces(
      hosts: const [
        WorkspaceHost(id: 'computer', label: 'Computer', online: true),
        WorkspaceHost(
          id: 'second-computer',
          label: 'Second computer',
          online: true,
        ),
      ],
    );
    final vm = NewSessionViewModel(repo, launch: defaultLaunch);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vm,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const NewSessionPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    repo.onBrowseHost = (_, _) async =>
        throw const WorkspaceFailure('The computer did not respond.');
    await vm.selectHost('second-computer');
    await tester.pumpAndSettle();

    expect(find.text('The computer did not respond.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('new-session-retry-browse')),
      findsOneWidget,
    );

    repo.onBrowseHost = (hostId, _) async => directory('/$hostId');
    await tester.tap(find.byKey(const ValueKey('new-session-retry-browse')));
    await tester.pumpAndSettle();
    expect(find.text('/second-computer'), findsOneWidget);
    expect(find.text('The computer did not respond.'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
  });

  testWidgets('offline computers are visible but cannot be selected', (
    tester,
  ) async {
    final repo = FakeWorkspaces(
      hosts: const [
        WorkspaceHost(id: 'computer', label: 'Computer', online: true),
        WorkspaceHost(
          id: 'offline-computer',
          label: 'Offline computer',
          online: false,
        ),
      ],
    );
    final vm = NewSessionViewModel(repo, launch: defaultLaunch);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: vm,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const NewSessionPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('new-session-device-picker')));
    await tester.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('new-session-host-offline-computer')),
    );
    await tester.pumpAndSettle();
    expect((vm.state as NewSessionReady).host.id, 'computer');
    expect(repo.requestedHosts, isNot(contains('offline-computer')));
    expect(
      find.byKey(const ValueKey('new-session-device-sheet')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    vm.dispose();
  });
}
