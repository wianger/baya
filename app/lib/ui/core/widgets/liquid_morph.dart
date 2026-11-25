/// Popups that grow out of the finger: a small round drop where the tap
/// landed swells, on a spring, into the popup's own shape (and its corners
/// round off as it does), then shrinks back into the same spot on close.
/// Sheets, dialogs, menus and the search card all open this way.
library;

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Where the last touch went down, for popups to grow from.
abstract final class BayaTapOrigin {
  static Offset? last;

  /// Put around the app: notes every touch without taking it.
  static Widget track(Widget child) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) => last = event.position,
    child: child,
  );
}

/// A spring with a little overshoot: liquid, not elastic.
class LiquidCurve extends Curve {
  const LiquidCurve();

  static final _spring = SpringSimulation(
    const SpringDescription(mass: 1, stiffness: 210, damping: 21),
    0,
    1,
    0,
  );

  /// The time the spring takes to settle, in seconds.
  static const span = .62;

  @override
  double transformInternal(double t) => t >= 1 ? 1 : _spring.x(t * span);
}

/// How long a popup takes to swell in and to drain away.
const kLiquidIn = Duration(milliseconds: 520);
const kLiquidOut = Duration(milliseconds: 240);

/// Wraps a popup's visible surface. It reads its route's animation, so it
/// opens and closes with it.
class LiquidMorph extends StatelessWidget {
  const LiquidMorph({
    super.key,
    required this.child,
    required this.borderRadius,
    this.fallback = Alignment.center,
  });

  final Widget child;

  /// The popup's own corners, reached at the end.
  final BorderRadius borderRadius;

  /// Where it grows from when no touch started it (a keyboard, a timer).
  final Alignment fallback;

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    final origin = BayaTapOrigin.last;
    final grow = CurvedAnimation(
      parent: animation,
      curve: const LiquidCurve(),
      reverseCurve: Curves.easeInCubic,
    );
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = grow.value;
        if (animation.isCompleted) return child!;
        // The content shows once the drop is big enough to hold it.
        final fade = ((animation.value - .18) / .42).clamp(0.0, 1.0);
        return ClipPath(
          clipper: _DropClipper(
            context: context,
            origin: origin,
            fallback: fallback,
            t: t,
            radius: borderRadius,
          ),
          child: Opacity(opacity: Curves.easeOut.transform(fade), child: child),
        );
      },
    );
  }
}

class _DropClipper extends CustomClipper<Path> {
  _DropClipper({
    required this.context,
    required this.origin,
    required this.fallback,
    required this.t,
    required this.radius,
  });

  final BuildContext context;
  final Offset? origin;
  final Alignment fallback;
  final double t;
  final BorderRadius radius;

  @override
  Path getClip(Size size) {
    final box = context.findRenderObject() as RenderBox?;
    var start = fallback.alongSize(size);
    if (origin != null && box != null && box.hasSize) {
      final local = box.globalToLocal(origin!);
      // A touch outside the popup starts at its nearest edge.
      start = Offset(
        local.dx.clamp(0, size.width),
        local.dy.clamp(0, size.height),
      );
    }
    const drop = 44.0;
    final from = Rect.fromCenter(center: start, width: drop, height: drop);
    final full = Offset.zero & size;
    // The width runs a little ahead of the height, so the drop stretches
    // into shape rather than scaling: the liquid part.
    final tw = t.clamp(0.0, 1.12);
    final th = math.pow(t.clamp(0.0, 1.12), 1.25).toDouble();
    final rect = Rect.fromLTRB(
      lerpDouble(from.left, full.left, tw)!,
      lerpDouble(from.top, full.top, th)!,
      lerpDouble(from.right, full.right, tw)!,
      lerpDouble(from.bottom, full.bottom, th)!,
    ).intersect(full.inflate(8));
    final round = drop / 2;
    Radius corner(Radius end) {
      final r = lerpDouble(round, end.x, t.clamp(0.0, 1.0))!;
      return Radius.circular(
        math.min(r, math.min(rect.width, rect.height) / 2),
      );
    }

    return Path()..addRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: corner(radius.topLeft),
        topRight: corner(radius.topRight),
        bottomLeft: corner(radius.bottomLeft),
        bottomRight: corner(radius.bottomRight),
      ),
    );
  }

  @override
  bool shouldReclip(_DropClipper old) =>
      old.t != t || old.origin != origin || old.radius != radius;
}

/// A popup route whose surface morphs out of the tap: the dimmed page fades
/// in behind it; nothing slides.
Future<T?> showLiquid<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = true,
}) {
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _LiquidRoute<T>(
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: barrierColor ?? Colors.black.withValues(alpha: .32),
      transitionDuration: kLiquidIn,
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (routeContext, _, _) => builder(routeContext),
    ),
  );
}

/// Swells in on a spring, drains away quicker.
class _LiquidRoute<T> extends RawDialogRoute<T> {
  _LiquidRoute({
    required super.pageBuilder,
    super.barrierDismissible,
    super.barrierLabel,
    super.barrierColor,
    super.transitionDuration,
    super.transitionBuilder,
  });

  @override
  Duration get reverseTransitionDuration => kLiquidOut;
}
