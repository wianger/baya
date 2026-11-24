import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/terminals/herdr_terminals.dart';
import 'package:app/data/transport/noise.dart';
import 'package:app/l10n/app_localizations.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/terminals/terminal_page.dart';
import 'package:app/ui/terminals/terminals_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Map<String, dynamic> _t(
  String address, {
  String? status,
  String state = 'live',
  String program = 'fish',
}) => {
  'address': address,
  'argv': ['/usr/bin/fish'],
  'cwd': '/home/me/shop',
  'state': state,
  'title': '',
  'created_ms': 1000,
  'foreground': {
    'name': program,
    'cwd': '/home/me/shop',
    'pid': 1,
    'argv': <String>[],
  },
  'status': ?(status == null ? null : {'state': status, 'app': program}),
};

class _Link implements TerminalLink {
  bool online = true;
  bool available = true;
  final calls = <(String, Json)>[];
  final notes = <(String, Json)>[];
  // ignore: close_sinks
  final frames = StreamController<DataFrame>.broadcast();
  // ignore: close_sinks
  final events = StreamController<({String method, Json params})>.broadcast();
  // ignore: close_sinks
  final up = StreamController<void>.broadcast();
  List<Map<String, dynamic>> terminals = [
    _t('t1'),
    _t('t2', status: 'blocked', program: 'claude'),
    _t('t3', state: 'finished'),
  ];

  @override
  bool get isOnline => online;

  @override
  Future<Json> call(String method, Json params) async {
    calls.add((method, params));
    return switch (method) {
      '_baya/terminal_list' => {
        'available': available,
        'terminals': available ? terminals : <Object>[],
      },
      '_baya/terminal_attach' => {'terminal': _t(params['terminal'] as String)},
      '_baya/terminal_run' => _t('t9'),
      _ => <String, dynamic>{},
    };
  }

  @override
  void notify(String method, Json params) => notes.add((method, params));

  @override
  Stream<DataFrame> get data => frames.stream;

  @override
  Stream<({String method, Json params})> get news => events.stream;

  @override
  Stream<void> get onOnline => up.stream;

  List<Json> get attaches => [
    for (final (method, params) in calls)
      if (method == '_baya/terminal_attach') params,
  ];

  void paint(String text, {int offset = 0}) => frames.add(
    DataFrame(
      attaches.last['stream'] as int,
      offset,
      Uint8List.fromList(utf8.encode(text)),
    ),
  );

  List<String> get typed => [
    for (final (method, params) in notes)
      if (method == '_baya/terminal_input') params['data'] as String,
  ];
}

Widget _app(Widget home) => MaterialApp(
  theme: buildLightTheme(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  testWidgets('waiting terminals lead; herdr missing says how to get it', (
    tester,
  ) async {
    final link = _Link();
    await tester.pumpWidget(
      _app(
        TerminalsPage(
          launch: const TerminalsLaunch(hostId: 'h', label: 'PC'),
          repository: TerminalsRepository(link),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final waiting = tester.getTopLeft(
      find.byKey(const ValueKey('terminal-row-t2')),
    );
    final running = tester.getTopLeft(
      find.byKey(const ValueKey('terminal-row-t1')),
    );
    final ended = tester.getTopLeft(
      find.byKey(const ValueKey('terminal-row-t3')),
    );
    expect(waiting.dy, lessThan(running.dy));
    expect(running.dy, lessThan(ended.dy));
    expect(find.text('WAITING FOR YOU'), findsOneWidget);

    // A change on the computer lists again.
    link.terminals = [_t('t1')];
    link.events.add((method: '_baya/terminals_changed', params: const {}));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal-row-t2')), findsNothing);

    link.available = false;
    link.events.add((method: '_baya/terminals_changed', params: const {}));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('terminals-no-herdr')), findsOneWidget);
    expect(find.byKey(const Key('terminal-new')), findsNothing);
  });

  testWidgets('a new agent starts from a line and opens', (tester) async {
    final link = _Link();
    await tester.pumpWidget(
      _app(
        TerminalsPage(
          launch: const TerminalsLaunch(hostId: 'h', label: 'PC'),
          repository: TerminalsRepository(link),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('terminal-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'claude'));
    await tester.pumpAndSettle();
    final run = link.calls.firstWhere((c) => c.$1 == '_baya/terminal_run');
    expect(run.$2['line'], 'claude');
    expect(link.attaches.single['terminal'], 't9');
    expect(find.byType(TerminalPage), findsOneWidget);
  });

  testWidgets('the screen streams; keys, ctrl and reconnects reach it', (
    tester,
  ) async {
    final link = _Link();
    await tester.pumpWidget(
      _app(
        TerminalPage(
          repository: TerminalsRepository(link),
          terminal: HerdrTerminal.fromJson(_t('t1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final attach = link.attaches.single;
    expect(attach['terminal'], 't1');
    expect(attach['resumed'], false);
    expect(attach['cols'] as int, greaterThan(10));

    link.paint('hello from herdr\r\n');
    await tester.pumpAndSettle();
    Terminal screen() =>
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    expect(screen().buffer.lines[0].toString(), contains('hello from herdr'));
    // A frame out of order (a stale stream's) is not painted.
    link.paint('stale', offset: 999);
    await tester.pumpAndSettle();
    expect(screen().buffer.lines[1].toString().trim(), isEmpty);

    await tester.tap(find.byKey(const Key('terminal-key-interrupt')));
    await tester.tap(find.byKey(const Key('terminal-key-ctrl')));
    await tester.pump();
    tester.testTextInput.enterText('d');
    await tester.pump();
    expect(link.typed, ['\x03', '\x04']);

    // Back online: the same terminal again, on a new stream, as resumed.
    link.up.add(null);
    await tester.pumpAndSettle();
    expect(link.attaches, hasLength(2));
    expect(link.attaches.last['resumed'], true);
    expect(link.attaches.last['stream'], isNot(attach['stream']));
    // A fresh screen for the paint that follows.
    expect(screen().buffer.lines[0].toString().trim(), isEmpty);
    link.paint('repainted');
    await tester.pumpAndSettle();
    expect(screen().buffer.lines[0].toString(), contains('repainted'));

    link.events.add((
      method: '_baya/terminal_closed',
      params: {'stream': link.attaches.last['stream'], 'reason': 'exited'},
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('terminal-notice')), findsOneWidget);
    expect(find.byKey(const Key('terminal-keys')), findsNothing);
  });
}
