import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/workspaces/widgets/device_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(
  List<WorkspaceHost> devices,
  WorkspaceHost selected,
  ValueChanged<String> onChanged,
) => MaterialApp(
  theme: buildDarkTheme(),
  home: Scaffold(
    body: DevicePickerField(
      devices: devices,
      selected: selected,
      enabled: true,
      onChanged: onChanged,
    ),
  ),
);

void main() {
  testWidgets('searches a large device catalog and returns a later selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final devices = List.generate(
      18,
      (index) => WorkspaceHost(
        id: 'computer-$index',
        label: 'Computer $index',
        online: true,
      ),
    );
    String? picked;
    await tester.pumpWidget(wrap(devices, devices.first, (id) => picked = id));

    await tester.tap(find.byKey(const ValueKey('new-session-device-picker')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('new-session-device-sheet')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('new-session-device-search')),
      'computer-17',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey('new-session-host-computer-17')),
    );
    await tester.pumpAndSettle();
    expect(picked, 'computer-17');
    expect(
      find.byKey(const ValueKey('new-session-device-sheet')),
      findsNothing,
    );
  });

  testWidgets('offline devices stay visible and cannot be selected', (
    tester,
  ) async {
    const online = WorkspaceHost(
      id: 'computer',
      label: 'Computer',
      online: true,
    );
    const offline = WorkspaceHost(
      id: 'offline-computer',
      label: 'Offline computer',
      online: false,
    );
    String? picked;
    await tester.pumpWidget(
      wrap(const [online, offline], online, (id) => picked = id),
    );

    await tester.tap(find.byKey(const ValueKey('new-session-device-picker')));
    await tester.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('new-session-host-offline-computer')),
    );
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(
      find.byKey(const ValueKey('new-session-device-sheet')),
      findsOneWidget,
    );
  });

  testWidgets('device sheet shrinks for a short catalog', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const devices = [
      WorkspaceHost(id: 'one', label: 'One', online: true),
      WorkspaceHost(id: 'two', label: 'Two', online: true),
    ];
    await tester.pumpWidget(wrap(devices, devices.first, (_) {}));

    await tester.tap(find.byKey(const ValueKey('new-session-device-picker')));
    await tester.pumpAndSettle();
    final height = tester
        .getSize(find.byKey(const ValueKey('new-session-device-sheet')))
        .height;
    expect(height, lessThan(500));
  });
}
