import 'package:app/ui/screen/screen_gestures.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 400×200 picture at (0, 100) on the phone.
const _picture = Rect.fromLTWH(0, 100, 400, 200);

({ScreenGestures gestures, List<ScreenMessage> sent, List<double> zooms})
_setup(PointerMode mode) {
  final sent = <ScreenMessage>[];
  final zooms = <double>[];
  final gestures = ScreenGestures(
    send: sent.add,
    toScreen: (p) => _picture.contains(p)
        ? Offset(
            (p.dx - _picture.left) / _picture.width,
            (p.dy - _picture.top) / _picture.height,
          )
        : null,
    pictureSize: () => _picture.size,
    onZoom: (scale, _, _) => zooms.add(scale),
    mode: mode,
    speed: 1,
  );
  return (gestures: gestures, sent: sent, zooms: zooms);
}

Duration _ms(int ms) => Duration(milliseconds: ms);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('touchpad: a drag moves the pointer, a tap clicks', () {
    final (:gestures, :sent, zooms: _) = _setup(PointerMode.touchpad);
    gestures
      ..down(const PointerDownEvent(position: Offset(100, 200)))
      ..move(
        PointerMoveEvent(position: const Offset(140, 220), timeStamp: _ms(40)),
      )
      ..up(
        PointerUpEvent(position: const Offset(140, 220), timeStamp: _ms(80)),
      );
    expect(sent, [
      {
        'r': [0.1, 0.1],
      },
    ]);

    sent.clear();
    gestures
      ..down(
        PointerDownEvent(
          pointer: 2,
          position: const Offset(10, 10),
          timeStamp: _ms(1000),
        ),
      )
      ..up(
        PointerUpEvent(
          pointer: 2,
          position: const Offset(10, 10),
          timeStamp: _ms(1080),
        ),
      );
    expect(sent, [
      {'b': 'l', 'n': 1},
    ]);
    gestures.dispose();
  });

  test('touchpad: hold, then drag, drags', () {
    fakeAsync((async) {
      final (:gestures, :sent, zooms: _) = _setup(PointerMode.touchpad);
      gestures.down(const PointerDownEvent(position: Offset(100, 200)));
      async.elapse(_ms(500));
      expect(sent, [
        {'b': 'l', 'd': true},
      ]);
      gestures
        ..move(
          PointerMoveEvent(
            position: const Offset(140, 200),
            timeStamp: _ms(600),
          ),
        )
        ..up(
          PointerUpEvent(position: const Offset(140, 200), timeStamp: _ms(700)),
        );
      expect(sent.last, {'b': 'l', 'd': false});
      expect(sent[1], {
        'r': [0.1, 0.0],
      });
    });
  });

  test('direct: a tap clicks where it lands; a drag drags there', () {
    final (:gestures, :sent, zooms: _) = _setup(PointerMode.direct);
    gestures
      ..down(const PointerDownEvent(position: Offset(200, 200)))
      ..up(
        PointerUpEvent(position: const Offset(200, 200), timeStamp: _ms(60)),
      );
    expect(sent, [
      {
        'm': [0.5, 0.5],
      },
      {'b': 'l', 'n': 1},
    ]);

    sent.clear();
    gestures
      ..down(
        PointerDownEvent(
          pointer: 3,
          position: const Offset(0, 100),
          timeStamp: _ms(1000),
        ),
      )
      ..move(
        PointerMoveEvent(
          pointer: 3,
          position: const Offset(100, 150),
          timeStamp: _ms(1050),
        ),
      )
      ..up(
        PointerUpEvent(
          pointer: 3,
          position: const Offset(100, 150),
          timeStamp: _ms(1100),
        ),
      );
    expect(sent, [
      {
        'm': [0.0, 0.0],
      },
      {'b': 'l', 'd': true},
      {
        'm': [0.25, 0.25],
      },
      {'b': 'l', 'd': false},
    ]);
    // Off the picture: nothing.
    sent.clear();
    gestures
      ..down(
        PointerDownEvent(
          pointer: 4,
          position: const Offset(10, 20),
          timeStamp: _ms(2000),
        ),
      )
      ..up(
        PointerUpEvent(
          pointer: 4,
          position: const Offset(10, 20),
          timeStamp: _ms(2050),
        ),
      );
    expect(sent, isEmpty);
  });

  test(
    'two fingers: tap for the right button, slide to scroll, pinch zooms here',
    () {
      final (:gestures, :sent, :zooms) = _setup(PointerMode.touchpad);
      gestures
        ..down(const PointerDownEvent(pointer: 1, position: Offset(100, 200)))
        ..down(const PointerDownEvent(pointer: 2, position: Offset(200, 200)))
        ..up(
          PointerUpEvent(
            pointer: 1,
            position: const Offset(100, 200),
            timeStamp: _ms(90),
          ),
        )
        ..up(
          PointerUpEvent(
            pointer: 2,
            position: const Offset(200, 200),
            timeStamp: _ms(100),
          ),
        );
      expect(sent, [
        {'b': 'r', 'n': 1},
      ]);

      sent.clear();
      gestures
        ..down(
          PointerDownEvent(
            pointer: 5,
            position: const Offset(100, 200),
            timeStamp: _ms(1000),
          ),
        )
        ..down(
          PointerDownEvent(
            pointer: 6,
            position: const Offset(200, 200),
            timeStamp: _ms(1000),
          ),
        );
      for (var y = 210.0; y <= 300; y += 10) {
        gestures
          ..move(PointerMoveEvent(pointer: 5, position: Offset(100, y)))
          ..move(PointerMoveEvent(pointer: 6, position: Offset(200, y)));
      }
      gestures
        ..up(PointerUpEvent(pointer: 5, timeStamp: _ms(1500)))
        ..up(PointerUpEvent(pointer: 6, timeStamp: _ms(1500)));
      final wheel = [
        for (final m in sent)
          if (m['w'] case final List<double> w) w[0],
      ];
      expect(wheel, isNotEmpty);
      expect(wheel.every((dy) => dy > 0), isTrue);
      expect(sent.where((m) => m.containsKey('b')), isEmpty);

      sent.clear();
      gestures
        ..down(
          PointerDownEvent(
            pointer: 7,
            position: const Offset(150, 200),
            timeStamp: _ms(3000),
          ),
        )
        ..down(
          PointerDownEvent(
            pointer: 8,
            position: const Offset(250, 200),
            timeStamp: _ms(3000),
          ),
        );
      for (var d = 60.0; d <= 120; d += 10) {
        gestures
          ..move(PointerMoveEvent(pointer: 7, position: Offset(200 - d, 200)))
          ..move(PointerMoveEvent(pointer: 8, position: Offset(200 + d, 200)));
      }
      expect(sent, isEmpty);
      expect(zooms.fold<double>(1, (a, b) => a * b), greaterThan(1.5));
      gestures.dispose();
    },
  );
}
