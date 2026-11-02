import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Shared motion language for the app. Values follow a restrained
/// iOS-inspired rhythm: quick feedback, calm settling, and decisive exits.
abstract final class BayaMotion {
  static const fast = Duration(milliseconds: 140);
  static const standard = Duration(milliseconds: 240);
  static const emphasized = Duration(milliseconds: 380);
  static const morph = Duration(milliseconds: 300);
  static const scroll = Duration(milliseconds: 420);

  static const enter = Cubic(0.22, 1, 0.36, 1);
  static const exit = Cubic(0.4, 0, 1, 1);
  static const spring = Cubic(0.16, 1, 0.3, 1);
  static const morphSettle = Cubic(0.18, 0.94, 0.24, 1);
}

/// Lets a morphing popover keep its glass material visible while its contents
/// cross-fade into the final layout.
class BayaSurfaceContentMotion extends InheritedWidget {
  const BayaSurfaceContentMotion({
    super.key,
    required this.animation,
    this.surfaceScale,
    required super.child,
  });

  final Animation<double> animation;
  final Animation<double>? surfaceScale;

  static BayaSurfaceContentMotion? surfaceOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BayaSurfaceContentMotion>();

  static Animation<double>? maybeOf(BuildContext context) =>
      surfaceOf(context)?.animation;

  @override
  bool updateShouldNotify(BayaSurfaceContentMotion oldWidget) =>
      animation != oldWidget.animation;
}

/// A quiet content entrance for newly inserted messages and grouped surfaces.
///
/// The platform Reduce Motion preference removes the animation completely.
class BayaReveal extends StatelessWidget {
  const BayaReveal({
    super.key,
    required this.child,
    this.offset = 8,
    this.scale = 0.99,
  });

  final Widget child;
  final double offset;
  final double scale;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: BayaMotion.emphasized,
      curve: BayaMotion.spring,
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

/// Quiet canvas behind the functional glass layer.
///
/// Content is the visual subject. A barely perceptible tonal transition keeps
/// large screens from looking flat without introducing the colored glows and
/// moving light fields that competed with text in earlier builds.
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
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: translucent ? Colors.transparent : colors.bg,
        gradient: translucent
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(
                    colors.bg,
                    colors.surface,
                    Theme.of(context).brightness == Brightness.dark
                        ? .035
                        : .16,
                  )!,
                  colors.bg,
                ],
                stops: const [0, .42],
              ),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}
