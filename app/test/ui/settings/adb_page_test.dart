import 'package:app/ui/settings/adb_page.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/acp_harness.dart';

void main() {
  testWidgets('pair, connect, and the agents get the device name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = FakeHost();
    var connected = false;
    final asked = <String, Object?>{};
    host.handlers['_baya/adb_status'] = (_) => {
      'adb': 'C:/sdk/adb.exe',
      'tools': connected,
      'devices': [
        if (connected) {'serial': '100.80.1.2:41234', 'state': 'device'},
      ],
    };
    host.handlers['_baya/adb_pair'] = (params) {
      asked['pair'] = params['address'];
      asked['code'] = params['code'];
      return {'output': 'Successfully paired'};
    };
    host.handlers['_baya/adb_connect'] = (params) {
      asked['connect'] = params['address'];
      connected = true;
      return {'serial': params['address'], 'output': 'connected to'};
    };
    final hosts = testHosts(MemoryStorage([testPeer(name: 'studio')]), host);
    await hosts.start();
    await pumpOnline(tester, hosts);
    await tester.pumpWidget(
      ChangeNotifierProvider<Hosts>.value(
        value: hosts,
        child: MaterialApp(
          home: AdbPage(phoneAddress: () async => '100.80.1.2'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    debugPrint(
      'TEXTS ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).take(8).toList()}',
    );
    expect(find.textContaining("isn't connected"), findsOneWidget);

    await tester.enterText(find.byKey(const Key('adb-pair-port')), '37001');
    await tester.enterText(find.byKey(const Key('adb-code')), '482913');
    await tester.tap(find.byKey(const Key('adb-pair')));
    await tester.pumpAndSettle();
    expect(asked['pair'], '100.80.1.2:37001');
    expect(asked['code'], '482913');

    await tester.enterText(find.byKey(const Key('adb-port')), '41234');
    await tester.tap(find.byKey(const Key('adb-connect')));
    await tester.pumpAndSettle();
    expect(asked['connect'], '100.80.1.2:41234');
    expect(
      find.text(
        'This phone is adb device 100.80.1.2:41234 (adb -s 100.80.1.2:41234 …)',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('mobile-mcp'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    hosts.dispose();
  });
}
