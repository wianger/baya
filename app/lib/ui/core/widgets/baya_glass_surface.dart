import 'dart:ui' as ui;

import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';

/// Shared Apple-style frosted surfaces used across navigation, content and
/// modal layers.
///
/// Each role changes blur strength, tint and elevation without changing the
/// semantic palette. High-contrast mode deliberately falls back to an opaque
/// semantic fill because translucency can hide focus rings and text.
enum BayaGlassRole { navigation, card, control, content, user, overlay, brand }

class BayaGlassSurface extends StatelessWidget {
  const BayaGlassSurface({
    super.key,
    required this.child,
    this.radius = 28,
    this.borderRadius,
    this.padding = EdgeInsets.zero,
    this.elevated = true,
    this.emphasized = false,
    this.emphasisColor,
    this.role = BayaGlassRole.card,
    this.blurSigma,
  });

  final Widget child;
  final double radius;
  final BorderRadiusGeometry? borderRadius;
  final EdgeInsetsGeometry padding;
  final bool elevated;
  final bool emphasized;
  final Color? emphasisColor;
  final BayaGlassRole role;

  /// Optional override for unusually large or nested surfaces.
  final double? blurSigma;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final highContrast = MediaQuery.maybeOf(context)?.highContrast ?? false;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final corners = borderRadius ?? BorderRadius.circular(radius);
    final resolvedEmphasisColor = emphasisColor ?? colors.accent;
    final contentMotion = BayaSurfaceContentMotion.surfaceOf(context);
    final (
      topFill,
      bottomFill,
      tint,
      sigma,
      shadowBlur,
      shadowOffset,
    ) = switch (role) {
      BayaGlassRole.navigation => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.28 : 0.56),
        colors.glassFill.withValues(alpha: dark ? 0.18 : 0.42),
        colors.glassTint.withValues(alpha: dark ? 0.20 : 0.26),
        26.0,
        18.0,
        5.0,
      ),
      BayaGlassRole.card => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.19 : 0.46),
        colors.glassFill.withValues(alpha: dark ? 0.11 : 0.30),
        colors.glassTint.withValues(alpha: dark ? 0.14 : 0.18),
        20.0,
        16.0,
        4.0,
      ),
      BayaGlassRole.control => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.23 : 0.48),
        colors.glassFill.withValues(alpha: dark ? 0.13 : 0.32),
        colors.glassTint.withValues(alpha: dark ? 0.17 : 0.20),
        14.0,
        7.0,
        2.0,
      ),
      BayaGlassRole.content => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.13 : 0.38),
        colors.glassFill.withValues(alpha: dark ? 0.08 : 0.24),
        colors.glassTint.withValues(alpha: dark ? 0.11 : 0.15),
        16.0,
        10.0,
        3.0,
      ),
      BayaGlassRole.user => (
        colors.userBubble.withValues(alpha: dark ? 0.94 : 0.95),
        colors.userBubble.withValues(alpha: dark ? 0.86 : 0.90),
        colors.userBubble.withValues(alpha: dark ? 0.90 : 0.93),
        14.0,
        12.0,
        3.0,
      ),
      BayaGlassRole.overlay => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.34 : 0.62),
        colors.glassFill.withValues(alpha: dark ? 0.22 : 0.46),
        colors.glassTint.withValues(alpha: dark ? 0.27 : 0.30),
        30.0,
        24.0,
        6.0,
      ),
      BayaGlassRole.brand => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.24 : 0.52),
        colors.glassFill.withValues(alpha: dark ? 0.14 : 0.34),
        colors.glassTint.withValues(alpha: dark ? 0.18 : 0.22),
        22.0,
        14.0,
        4.0,
      ),
    };
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: highContrast
            ? role == BayaGlassRole.user
                  ? colors.userBubble
                  : role == BayaGlassRole.content
                  ? colors.surface
                  : colors.inputFill
            : null,
        gradient: highContrast
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0, 0.48, 1],
                colors: [topFill, tint, bottomFill],
              ),
        borderRadius: corners,
        border: Border.all(
          color: highContrast
              ? colors.muted2
              : emphasized
              ? resolvedEmphasisColor.withValues(alpha: 0.52)
              : colors.glassEdge,
          width: highContrast
              ? 1.2
              : emphasized
              ? 0.9
              : 0.7,
        ),
      ),
      child: Stack(
        children: [
          if (!highContrast)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: corners,
                    gradient: RadialGradient(
                      center: const Alignment(-0.68, -1.05),
                      radius: 1.32,
                      colors: [
                        colors.glassHighlight,
                        colors.glassHighlight.withValues(
                          alpha: colors.glassHighlight.a * 0.30,
                        ),
                        colors.glassHighlight.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.34, 1],
                    ),
                  ),
                ),
              ),
            ),
          if (!highContrast)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: corners,
                    gradient: LinearGradient(
                      begin: const Alignment(-1, -1),
                      end: const Alignment(0.15, 0.8),
                      colors: [
                        colors.glassHighlight.withValues(
                          alpha: colors.glassHighlight.a * 0.16,
                        ),
                        colors.glassHighlight.withValues(alpha: 0.005),
                        colors.glassHighlight.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.22, 0.58],
                    ),
                  ),
                ),
              ),
            ),
          if (!highContrast)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: corners,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        colors.glassInnerShadow.withValues(alpha: 0),
                        colors.glassInnerShadow.withValues(alpha: 0),
                        colors.glassInnerShadow,
                      ],
                      stops: const [0, 0.68, 1],
                    ),
                  ),
                ),
              ),
            ),
          if (!highContrast && role == BayaGlassRole.brand)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: corners,
                    gradient: LinearGradient(
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                      colors: [
                        colors.glassCool.withValues(alpha: dark ? 0.16 : 0.12),
                        colors.glassCool.withValues(alpha: 0),
                        colors.glassWarm.withValues(alpha: dark ? 0.11 : 0.10),
                      ],
                      stops: const [0, 0.52, 1],
                    ),
                  ),
                ),
              ),
            ),
          if (contentMotion == null)
            Padding(padding: padding, child: child)
          else
            AnimatedBuilder(
              animation: Listenable.merge([
                contentMotion.animation,
                ?contentMotion.surfaceScale,
              ]),
              child: Padding(padding: padding, child: child),
              builder: (context, child) => Transform.scale(
                key: const ValueKey('baya-surface-content-scale'),
                scale: contentMotion.surfaceScale == null
                    ? 1
                    : 1 / contentMotion.surfaceScale!.value.clamp(0.01, 1.0),
                alignment: Alignment.topRight,
                child: Opacity(
                  key: const ValueKey('baya-surface-content-opacity'),
                  opacity: contentMotion.animation.value.clamp(0.0, 1.0),
                  child: child,
                ),
              ),
            ),
          if (!highContrast)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey('baya-glass-rim'),
                  painter: _BayaGlassRimPainter(
                    corners: corners.resolve(Directionality.of(context)),
                    highlight: colors.glassHighlight,
                    shade: colors.glassShade,
                    accent: resolvedEmphasisColor,
                    emphasized: emphasized,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        boxShadow: elevated && !highContrast
            ? [
                BoxShadow(
                  color: colors.glassShadow,
                  blurRadius: shadowBlur,
                  offset: Offset(0, shadowOffset),
                ),
                BoxShadow(
                  color: colors.glassContactShadow,
                  blurRadius: 4,
                  spreadRadius: -1,
                  offset: Offset(0, 1),
                ),
                if (emphasized)
                  BoxShadow(
                    color: resolvedEmphasisColor.withValues(alpha: 0.12),
                    blurRadius: 24,
                    spreadRadius: 1,
                    offset: const Offset(0, 4),
                  ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: corners,
        child: highContrast
            ? surface
            : BackdropFilter(
                filter: ui.ImageFilter.blur(
                  sigmaX: blurSigma ?? sigma,
                  sigmaY: blurSigma ?? sigma,
                ),
                child: surface,
              ),
      ),
    );
  }
}

/// A primary action rendered on the shared frosted-glass material.
///
/// The internal [FilledButton] remains a real Material button so keyboard
/// focus, semantics and widget-level tests keep working. Its fill is
/// transparent so the surface owns the blur, rim light and press feedback.
class BayaGlassButton extends StatelessWidget {
  const BayaGlassButton({
    super.key,
    this.buttonKey,
    required this.onPressed,
    required this.label,
    this.icon,
    this.prominent = true,
    this.minimumSize = const Size(44, 48),
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  final VoidCallback? onPressed;
  final Key? buttonKey;
  final Widget label;
  final Widget? icon;
  final bool prominent;
  final Size minimumSize;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onPressed != null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      opacity: enabled ? 1 : 0.58,
      child: BayaGlassSurface(
        role: BayaGlassRole.control,
        radius: 28,
        elevated: false,
        emphasized: prominent && enabled,
        child: FilledButton(
          key: buttonKey,
          onPressed: onPressed,
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(minimumSize),
            padding: WidgetStatePropertyAll(padding),
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) return colors.muted;
              return prominent ? colors.accent : colors.text;
            }),
            overlayColor: WidgetStatePropertyAll(
              colors.accent.withValues(alpha: 0.14),
            ),
            elevation: const WidgetStatePropertyAll(0),
            shadowColor: const WidgetStatePropertyAll(Colors.transparent),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            animationDuration: const Duration(milliseconds: 180),
          ),
          child: icon == null
              ? label
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconTheme.merge(
                      data: const IconThemeData(size: 18),
                      child: icon!,
                    ),
                    const SizedBox(width: 8),
                    Flexible(fit: FlexFit.loose, child: label),
                  ],
                ),
        ),
      ),
    );
  }
}

class _BayaGlassRimPainter extends CustomPainter {
  const _BayaGlassRimPainter({
    required this.corners,
    required this.highlight,
    required this.shade,
    required this.accent,
    required this.emphasized,
  });

  final BorderRadius corners;
  final Color highlight;
  final Color shade;
  final Color accent;
  final bool emphasized;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rimRect = rect.deflate(0.6);
    final rrect = corners.toRRect(rimRect);
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = emphasized ? 1 : 0.8
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          highlight,
          highlight.withValues(alpha: highlight.a * 0.34),
          emphasized ? accent.withValues(alpha: 0.58) : shade,
          highlight.withValues(alpha: highlight.a * 0.52),
        ],
        stops: const [0, 0.36, 0.72, 1],
      ).createShader(rect);
    canvas.drawRRect(rrect, rimPaint);

    final sheen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          highlight.withValues(alpha: 0),
          highlight,
          highlight.withValues(alpha: 0),
        ],
        stops: const [0.08, 0.46, 0.88],
      ).createShader(Rect.fromLTWH(0, 0, size.width, 1.2));
    canvas.drawLine(
      Offset(corners.topLeft.x + 8, 0.8),
      Offset(size.width - 8, 0.8),
      sheen,
    );
  }

  @override
  bool shouldRepaint(_BayaGlassRimPainter oldDelegate) =>
      oldDelegate.corners != corners ||
      oldDelegate.highlight != highlight ||
      oldDelegate.shade != shade ||
      oldDelegate.accent != accent ||
      oldDelegate.emphasized != emphasized;
}
