import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Shared motion language for the app. Values follow a restrained
/// iOS-inspired rhythm: quick feedback, calm settling, and decisive exits.
abstract final class BayaMotion {
  static const fast = Duration(milliseconds: 140);
  static const standard = Duration(milliseconds: 240);
  static const emphasized = Duration(milliseconds: 380);
  static const morph = Duration(milliseconds: 440);
  static const scroll = Duration(milliseconds: 420);

  static const enter = Cubic(0.22, 1, 0.36, 1);
  static const exit = Cubic(0.4, 0, 1, 1);
  static const spring = Cubic(0.16, 1, 0.3, 1);
  static const morphSettle = Cubic(0.16, 1.015, 0.28, 1);
}

/// Lets a morphing popover keep its glass material visible while its contents
/// cross-fade into the final layout.
class BayaSurfaceContentMotion extends InheritedWidget {
  const BayaSurfaceContentMotion({
    super.key,
    required this.animation,
    required super.child,
  });

  final Animation<double> animation;

  static Animation<double>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<BayaSurfaceContentMotion>()
      ?.animation;

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

/// Atmospheric canvas behind translucent controls. The soft color fields give
/// glass layers something to refract without competing with reading content.
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
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colors.bg,
                  Color.alphaBlend(colors.glassCool, colors.bg),
                  Color.alphaBlend(colors.backdropAccent, colors.bg),
                  Color.alphaBlend(colors.backdropWarmth, colors.bg),
                  colors.bg,
                ],
                stops: const [0, 0.28, 0.58, 0.82, 1],
              ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned(
              top: -210,
              right: -170,
              width: 500,
              height: 500,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        colors.glassCool,
                        colors.glassCool.withValues(alpha: 0),
                      ],
                      stops: const [0, 1],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 120,
              left: -240,
              width: 520,
              height: 520,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        colors.backdropAccent,
                        colors.backdropAccent.withValues(alpha: 0),
                      ],
                      stops: const [0, 1],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -260,
              left: -170,
              width: 560,
              height: 560,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        colors.backdropWarmth,
                        colors.backdropWarmth.withValues(alpha: 0),
                      ],
                      stops: const [0, 1],
                    ),
                  ),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}
