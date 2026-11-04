import 'dart:math' as math;

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Shared motion language for the app. Values follow a restrained
/// Motion rhythm: quick feedback, calm settling, and decisive exits.
abstract final class BayaMotion {
  static const fast = Duration(milliseconds: 140);
  static const standard = Duration(milliseconds: 240);
  static const emphasized = Duration(milliseconds: 380);
  static const scroll = Duration(milliseconds: 420);

  static const enter = Cubic(0.22, 1, 0.36, 1);
  static const exit = Cubic(0.4, 0, 1, 1);
  static const spring = Cubic(0.16, 1, 0.3, 1);
}

/// Whether [BayaReveal]s below play their entrance. A list sets it per row
/// so only rows that arrive while the user watches animate, and each only
/// once: not a history that loads, nor a row scrolled back into view.
class RevealGate extends InheritedWidget {
  const RevealGate({super.key, required this.animate, required super.child});

  final bool animate;

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<RevealGate>()?.animate ?? true;

  // Read once, when a reveal starts; later changes must not replay it.
  @override
  bool updateShouldNotify(RevealGate oldWidget) => false;
}

/// A quiet content entrance for newly inserted messages and grouped surfaces.
/// [delay] staggers the rows of a list.
///
/// The platform Reduce Motion preference removes the animation completely.
/// Either way the widget tree is the same, so turning an entrance off never
/// rebuilds what it wraps.
class BayaReveal extends StatelessWidget {
  const BayaReveal({
    super.key,
    required this.child,
    this.offset = 8,
    this.scale = 0.99,
    this.delay = Duration.zero,
  });

  final Widget child;
  final double offset;
  final double scale;
  final Duration delay;

  /// The delay of row [index] in a staggered list; rows past the first
  /// screenful start together.
  static Duration stagger(int index) =>
      Duration(milliseconds: 36 * math.min(index, 8));

  @override
  Widget build(BuildContext context) {
    final play =
        RevealGate.of(context) && !MediaQuery.disableAnimationsOf(context);
    final total = BayaMotion.emphasized + delay;
    return TweenAnimationBuilder<double>(
      // [begin] is used only on the first build.
      tween: Tween(begin: play ? 0 : 1, end: 1),
      duration: total,
      curve: delay == Duration.zero
          ? BayaMotion.spring
          : Interval(
              delay.inMicroseconds / total.inMicroseconds,
              1,
              curve: BayaMotion.spring,
            ),
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, offset * (1 - value)),
            child: Transform.scale(
              scale: scale + (1 - scale) * value,
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// Material's fade-through: the outgoing screen fades away first, then the
/// incoming one fades in while settling from slightly smaller. For moving
/// between peers (one session to another) rather than deeper into one.
Widget bayaFadeThrough(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  return FadeTransition(
    opacity: ReverseAnimation(
      CurvedAnimation(
        parent: secondaryAnimation,
        curve: const Interval(0, .3, curve: Curves.easeIn),
      ),
    ),
    child: FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: const Interval(.3, 1, curve: Curves.easeOut),
        reverseCurve: const Interval(0, .3, curve: Curves.easeIn),
      ),
      child: ScaleTransition(
        scale: Tween<double>(begin: .96, end: 1).animate(
          CurvedAnimation(
            parent: animation,
            curve: const Interval(.3, 1, curve: BayaMotion.enter),
          ),
        ),
        child: child,
      ),
    ),
  );
}

/// The app's dialogs: Material's, rising with a short spring as they fade.
Future<T?> showBayaDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  animationStyle: const AnimationStyle(
    duration: BayaMotion.standard,
    reverseDuration: BayaMotion.fast,
    curve: BayaMotion.enter,
    reverseCurve: BayaMotion.exit,
  ),
  builder: (context) => _DialogRise(child: builder(context)),
);

class _DialogRise extends StatelessWidget {
  const _DialogRise({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return ScaleTransition(
      scale: Tween<double>(begin: .92, end: 1).animate(
        CurvedAnimation(
          parent: animation,
          curve: BayaMotion.spring,
          reverseCurve: BayaMotion.exit,
        ),
      ),
      child: child,
    );
  }
}

/// The page canvas: the M3 `surface` color.
class BayaBackdrop extends StatelessWidget {
  const BayaBackdrop({
    super.key,
    required this.child,
    this.translucent = false,
  });

  final Widget child;
  final bool translucent;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: translucent ? Colors.transparent : context.colors.bg,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
