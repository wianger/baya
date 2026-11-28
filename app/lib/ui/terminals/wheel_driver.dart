/// Turns a finger on a full-screen program into its wheel: a line's height
/// of drag is one turn; the first turn goes at once, the rest together
/// every [every] (each makes the program paint its screen again); and a
/// flick keeps turning after the finger lifts, slowing as a list does.
library;

import 'dart:async';

class WheelDriver {
  WheelDriver({
    required this.onTurns,
    this.every = const Duration(milliseconds: 40),
  });

  /// Turns to send: positive is up (older output), negative down.
  final void Function(int turns) onTurns;
  final Duration every;

  /// Pixels a turn takes; set from the text size.
  double line = 16;

  double _drag = 0;
  int _pending = 0;
  Timer? _throttle;
  Timer? _fling;
  double _velocity = 0;
  final _recent = <(Duration, double)>[];

  /// The finger moved [dy] pixels (down is positive) at [at].
  void drag(double dy, Duration at) {
    _fling?.cancel();
    _recent
      ..add((at, dy))
      ..removeWhere((e) => at - e.$1 > const Duration(milliseconds: 100));
    _add(dy);
  }

  /// The finger lifted: a flick goes on by itself.
  void release() {
    if (_recent.length < 2) {
      _recent.clear();
      return;
    }
    final span = _recent.last.$1 - _recent.first.$1;
    final moved = _recent.fold<double>(0, (sum, e) => sum + e.$2);
    _recent.clear();
    if (span <= Duration.zero) return;
    _velocity = moved / (span.inMicroseconds / 1e6);
    if (_velocity.abs() < 400) return;
    const frame = Duration(milliseconds: 16);
    _fling = Timer.periodic(frame, (timer) {
      _velocity *= .92;
      if (_velocity.abs() < 60) {
        timer.cancel();
        return;
      }
      _add(_velocity * frame.inMicroseconds / 1e6);
    });
  }

  /// A new touch, or the page going: everything stops.
  void stop() {
    _fling?.cancel();
    _recent.clear();
    _drag = 0;
  }

  void dispose() {
    stop();
    _throttle?.cancel();
  }

  void _add(double dy) {
    _drag += dy;
    while (_drag.abs() >= line) {
      final up = _drag > 0;
      _drag -= up ? line : -line;
      _pending += up ? 1 : -1;
    }
    if (_pending == 0) return;
    // The first at once; then together, every [every].
    if (_throttle == null) {
      _flush();
      _throttle = Timer.periodic(every, (timer) {
        if (_pending == 0) {
          timer.cancel();
          _throttle = null;
        } else {
          _flush();
        }
      });
    }
  }

  void _flush() {
    final turns = _pending;
    _pending = 0;
    if (turns != 0) onTurns(turns);
  }
}
