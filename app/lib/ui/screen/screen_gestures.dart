/// Touches on the phone, turned into the computer's mouse.
///
/// Touchpad (the default, as on a laptop): drag moves the pointer, tap
/// clicks, hold then drag drags, two fingers tap for the right button and
/// slide to scroll. Direct: the finger is the pointer — tap clicks there,
/// drag drags, hold clicks right. In both, a pinch zooms the picture on the
/// phone and two fingers then pan it; nothing about that reaches the
/// computer.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

enum PointerMode { touchpad, direct }

typedef ScreenMessage = Map<String, Object?>;

class ScreenGestures {
  ScreenGestures({
    required this.send,
    required this.toScreen,
    required this.pictureSize,
    required this.onZoom,
    this.mode = PointerMode.touchpad,
    this.speed = 1.6,
  });

  /// Input for the computer.
  final void Function(ScreenMessage message) send;

  /// A point on the phone as a fraction of the computer's screen, or null
  /// off the picture.
  final Offset? Function(Offset local) toScreen;

  /// The picture's size on the phone now (zoom included), for touchpad
  /// moves: a finger across the picture crosses the screen ×[speed].
  final Size Function() pictureSize;

  /// The picture zooms by `scale` about `focal` and pans by `pan`.
  final void Function(double scale, Offset focal, Offset pan) onZoom;

  PointerMode mode;
  double speed;

  static const _slop = 8.0;
  static const _tapTime = Duration(milliseconds: 260);
  static const _holdTime = Duration(milliseconds: 420);

  final _points = <int, Offset>{};
  final _starts = <int, Offset>{};
  Duration _downAt = Duration.zero;
  bool _moved = false;
  bool _dragging = false;
  Timer? _hold;
  int _maxPointers = 0;

  // Two fingers: zooming the picture or scrolling the computer.
  String? _twoFinger;
  double _spread0 = 0;
  double _spreadLast = 0;
  Offset _centerLast = Offset.zero;
  double _wheelY = 0;
  double _wheelX = 0;

  Offset get _center {
    final points = _points.values.take(2).toList();
    return (points[0] + points[1]) / 2;
  }

  double get _spread {
    final points = _points.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  void down(PointerDownEvent event) {
    _points[event.pointer] = event.localPosition;
    _starts[event.pointer] = event.localPosition;
    _maxPointers = math.max(_maxPointers, _points.length);
    if (_points.length == 1) {
      _downAt = event.timeStamp;
      _moved = false;
      _dragging = false;
      _twoFinger = null;
      _hold?.cancel();
      _hold = Timer(_holdTime, _held);
    } else if (_points.length == 2) {
      _hold?.cancel();
      _spread0 = _spreadLast = _spread;
      _centerLast = _center;
      _wheelX = _wheelY = 0;
    }
  }

  /// A finger held still: a drag begins (touchpad), or a right click
  /// (direct).
  void _held() {
    if (_points.length != 1 || _moved) return;
    unawaited(HapticFeedback.mediumImpact());
    if (mode == PointerMode.touchpad) {
      _dragging = true;
      send({'b': 'l', 'd': true});
    } else {
      final at = toScreen(_points.values.first);
      if (at == null) return;
      send({
        'm': [at.dx, at.dy],
      });
      send({'b': 'r', 'n': 1});
      _moved = true; // Spent: lifting it does nothing more.
    }
  }

  void move(PointerMoveEvent event) {
    final last = _points[event.pointer];
    if (last == null) return;
    _points[event.pointer] = event.localPosition;
    if (_points.length >= 2) {
      _two();
      return;
    }
    if (_maxPointers > 1) return; // The rest of a two-finger gesture.
    final start = _starts[event.pointer]!;
    if (!_moved && (event.localPosition - start).distance < _slop) return;
    if (!_moved) {
      _moved = true;
      _hold?.cancel();
      if (mode == PointerMode.direct) {
        final at = toScreen(start);
        if (at != null) {
          send({
            'm': [at.dx, at.dy],
          });
          send({'b': 'l', 'd': true});
          _dragging = true;
        }
      }
    }
    if (mode == PointerMode.touchpad) {
      final size = pictureSize();
      if (size.width <= 0 || size.height <= 0) return;
      final delta = event.localPosition - last;
      send({
        'r': [delta.dx / size.width * speed, delta.dy / size.height * speed],
      });
    } else if (_dragging) {
      final at = toScreen(event.localPosition);
      if (at != null) {
        send({
          'm': [at.dx, at.dy],
        });
      }
    }
  }

  void _two() {
    final center = _center;
    final spread = _spread;
    if (_twoFinger == null) {
      final ratio = _spread0 == 0 ? 1.0 : spread / _spread0;
      if ((ratio - 1).abs() > .12) {
        _twoFinger = 'zoom';
      } else if ((center - _centerLast).distance > _slop) {
        _twoFinger = 'scroll';
      } else {
        return;
      }
      _spreadLast = spread;
      _centerLast = center;
      return;
    }
    if (_twoFinger == 'zoom') {
      onZoom(
        _spreadLast == 0 ? 1 : spread / _spreadLast,
        center,
        center - _centerLast,
      );
    } else {
      // Natural scrolling: the page follows the fingers.
      final delta = center - _centerLast;
      _wheelY += delta.dy / 48;
      _wheelX -= delta.dx / 48;
      if (_wheelY.abs() >= .1 || _wheelX.abs() >= .1) {
        send({
          'w': [_wheelY, _wheelX],
        });
        _wheelX = _wheelY = 0;
      }
    }
    _spreadLast = spread;
    _centerLast = center;
  }

  void up(PointerEvent event) {
    final start = _starts.remove(event.pointer);
    final at = _points.remove(event.pointer);
    if (_points.isNotEmpty) return;
    _hold?.cancel();
    final quick = event.timeStamp - _downAt < _tapTime;
    if (_maxPointers >= 2) {
      // Two fingers that only tapped: the right button.
      if (_twoFinger == null && quick) {
        if (mode == PointerMode.direct && at != null) {
          final there = toScreen(at);
          if (there != null) {
            send({
              'm': [there.dx, there.dy],
            });
          }
        }
        send({'b': 'r', 'n': 1});
      }
    } else if (_dragging) {
      send({'b': 'l', 'd': false});
    } else if (!_moved && start != null && event is PointerUpEvent) {
      if (mode == PointerMode.direct) {
        final there = toScreen(start);
        if (there == null) return _reset();
        send({
          'm': [there.dx, there.dy],
        });
      }
      send({'b': 'l', 'n': 1});
    }
    _reset();
  }

  void _reset() {
    _dragging = false;
    _moved = false;
    _maxPointers = 0;
    _twoFinger = null;
  }

  void dispose() => _hold?.cancel();
}
