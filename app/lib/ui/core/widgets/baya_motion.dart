import 'dart:math' as math;

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Shared motion language for the app: quick feedback, short settling,
/// decisive exits. Things fade and rise a few pixels; nothing scales text,
/// which shimmers as it resamples.
abstract final class BayaMotion {
  // DeepSeek's three durations and standard curves.
  static const fast = Duration(milliseconds: 100);
  static const standard = Duration(milliseconds: 200);
  static const emphasized = Duration(milliseconds: 300);
  static const scroll = Duration(milliseconds: 300);

  static const enter = Cubic(0, 0, .2, 1);
  static const exit = Cubic(.4, 0, 1, 1);
  static const spring = Cubic(.4, 0, .2, 1);
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

/// A quiet content entrance for newly inserted messages and grouped surfaces:
/// a fade while rising [offset] pixels. [delay] staggers the rows of a list.
///
/// It runs on the compositor (an opacity and a translation layer driven by
/// one controller), so the child is built once, not every frame. The
/// platform Reduce Motion preference removes it; either way the widget tree
/// is the same, so turning an entrance off never rebuilds what it wraps.
class BayaReveal extends StatefulWidget {
  const BayaReveal({
    super.key,
    required this.child,
    this.offset = 8,
    this.delay = Duration.zero,
  });

  final Widget child;
  final double offset;
  final Duration delay;

  /// The delay of row [index] in a staggered list; rows past the first
  /// screenful start together.
  static Duration stagger(int index) =>
      Duration(milliseconds: 30 * math.min(index, 8));

  @override
  State<BayaReveal> createState() => _BayaRevealState();
}

class _BayaRevealState extends State<BayaReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _rise;

  @override
  void initState() {
    super.initState();
    final total = BayaMotion.emphasized + widget.delay;
    _controller = AnimationController(vsync: this, duration: total);
    final start = widget.delay.inMicroseconds / total.inMicroseconds;
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, 1, curve: BayaMotion.spring),
    );
    // The fade finishes early: what rises is readable while it settles.
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, start + (1 - start) * .6, curve: Curves.easeOut),
    );
    _rise = Tween(
      begin: Offset(0, widget.offset),
      end: Offset.zero,
    ).animate(curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decided once, on the first build: later changes must not replay it.
    if (_controller.status != AnimationStatus.dismissed ||
        _controller.isAnimating) {
      return;
    }
    final play =
        RevealGate.of(context) && !MediaQuery.disableAnimationsOf(context);
    if (play) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: AnimatedBuilder(
      animation: _rise,
      builder: (context, child) =>
          Transform.translate(offset: _rise.value, child: child),
      child: widget.child,
    ),
  );
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
        scale: Tween<double>(begin: .98, end: 1).animate(
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
      scale: Tween<double>(begin: .96, end: 1).animate(
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
