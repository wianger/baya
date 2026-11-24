import 'dart:async';

import 'package:app/data/screen/remote_screen.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/acp_harness.dart';

class _Bridge implements MoonlightBridge {
  final calls = <(String, Map<String, Object?>?)>[];
  // ignore: close_sinks
  final feed = StreamController<Map<Object?, Object?>>.broadcast();
  bool paired = false;
  String pairState = 'PAIRED';

  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.add((method, arguments));
    return switch (method) {
      'paired' => paired,
      'pair' => {'state': pairState, 'cert': 'Q0VSVA=='},
      'start' => {'texture': 7},
      _ => null,
    };
  }

  @override
  Stream<Map<Object?, Object?>> get events => feed.stream;

  List<Map<String, Object?>> sent(String method) => [
    for (final (m, a) in calls)
      if (m == method) a ?? const {},
  ];
}

void main() {
  late FakeHost computer;
  late _Bridge bridge;
  String? pinToComputer;

  Future<RemoteScreenSession> session({bool ready = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    computer = FakeHost();
    computer.handlers['_baya/screen_info'] = (_) => ready
        ? {'ready': true, 'address': 'pc.tail.ts.net'}
        : {
            'ready': false,
            'reason': 'not_installed',
            'address': 'pc.tail.ts.net',
          };
    computer.handlers['_baya/screen_pair'] = (params) {
      pinToComputer = params['pin'] as String;
      return <String, Object?>{};
    };
    final hosts = testHosts(MemoryStorage([testPeer()]), computer);
    await hosts.start();
    await settle(40);
    bridge = _Bridge();
    return RemoteScreenSession(hosts.all.single, bridge: bridge);
  }

  test('a first visit pairs with the PIN the computer hands Sunshine, then streams', () async {
    final screen = await session();
    await screen.start(refresh: 120);
    final pair = bridge.sent('pair').single;
    expect(pair['address'], 'pc.tail.ts.net');
    expect(pair['pin'], matches(RegExp(r'^\d{4}$')));
    expect(pinToComputer, pair['pin']);
    final start = bridge.sent('start').single;
    expect(start, containsPair('cert', 'Q0VSVA=='));
    expect([start['width'], start['height'], start['fps']], [2560, 1440, 120]);
    expect(screen.texture, 7);

    bridge.feed.add({'event': 'started'});
    await settle();
    expect(screen.state, ScreenState.live);

    // Pointer, buttons, wheel, keys and text, in Moonlight's terms.
    screen
      ..input({
        'r': [0.1, -0.05],
      })
      ..input({
        'm': [0.5, 0.25],
      })
      ..input({'b': 'r', 'n': 1})
      ..input({
        'w': [1.0, 0.0],
      })
      ..input({
        'k': 'c',
        'mods': ['ctrl'],
      })
      ..input({'t': '你好'});
    await settle();
    expect(bridge.sent('mouseMove').single, {'dx': 256, 'dy': -72});
    expect(bridge.sent('mousePosition').single, {
      'x': 1280,
      'y': 360,
      'width': 2560,
      'height': 1440,
    });
    expect(bridge.sent('button'), [
      {'button': 3, 'down': true},
      {'button': 3, 'down': false},
    ]);
    expect(bridge.sent('scroll').single, {'amount': 120});
    expect(bridge.sent('key'), [
      {'code': 0x80a2, 'down': true, 'modifiers': 2},
      {'code': 0x8043, 'down': true, 'modifiers': 2},
      {'code': 0x8043, 'down': false, 'modifiers': 2},
      {'code': 0x80a2, 'down': false, 'modifiers': 0},
    ]);
    expect(bridge.sent('text').single, {'text': '你好'});

    // The next visit is already paired.
    final again = RemoteScreenSession(
      screen.hostForTest,
      bridge: bridge..paired = true,
    );
    bridge.calls.clear();
    await again.start();
    expect(bridge.sent('pair'), isEmpty);
    expect(bridge.sent('start').single['width'], 2560);
    screen.dispose();
    again.dispose();
  });

  test(
    'a computer without Sunshine says so, and a failed pairing ends it',
    () async {
      final screen = await session(ready: false);
      await screen.start();
      expect(screen.state, ScreenState.ended);
      expect(screen.reason, 'not_installed');
      expect(bridge.sent('start'), isEmpty);

      final other = await session();
      bridge.pairState = 'PIN_WRONG';
      await other.start();
      expect(other.state, ScreenState.ended);
      expect(other.reason, contains('PIN_WRONG'));
      expect(bridge.sent('start'), isEmpty);
      screen.dispose();
      other.dispose();
    },
  );

  test(
    'the stream follows the phone: 120 fps only where the screen shows it',
    () {
      expect(streamFor(ScreenQuality.best, 60).fps, 60);
      expect(streamFor(ScreenQuality.best, 120).fps, 120);
      expect(streamFor(ScreenQuality.saver, 120).height, 720);
    },
  );
}
