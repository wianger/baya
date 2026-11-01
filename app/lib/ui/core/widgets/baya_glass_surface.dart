import 'dart:ui' as ui;

import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';

/// Semantic material used by navigation, controls and content.
///
/// Frosting belongs to the functional layer that floats above content. Only
/// navigation, compact controls and elevated overlays receive a backdrop blur;
/// cards, message content, user bubbles and brand tiles use quiet opaque
/// surfaces. This keeps reading surfaces crisp and lets hierarchy come from
/// spacing, fill and typography rather than repeated glass effects.
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
    final usesBlur =
        !highContrast &&
        (role == BayaGlassRole.navigation ||
            role == BayaGlassRole.control ||
            (role == BayaGlassRole.overlay && elevated));
    final (
      topFill,
      bottomFill,
      tint,
      sigma,
      shadowBlur,
      shadowOffset,
    ) = switch (role) {
      BayaGlassRole.navigation => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.34 : 0.60),
        colors.glassFill.withValues(alpha: dark ? 0.22 : 0.44),
        colors.glassTint.withValues(alpha: dark ? 0.22 : 0.24),
        24.0,
        14.0,
        4.0,
      ),
      BayaGlassRole.card => (
        colors.surface,
        colors.surface,
        colors.surface,
        0.0,
        10.0,
        2.0,
      ),
      BayaGlassRole.control => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.28 : 0.52),
        colors.glassFill.withValues(alpha: dark ? 0.18 : 0.36),
        colors.glassTint.withValues(alpha: dark ? 0.20 : 0.18),
        14.0,
        8.0,
        2.0,
      ),
      BayaGlassRole.content => (
        colors.codeBg,
        colors.codeBg,
        colors.codeBg,
        0.0,
        0.0,
        0.0,
      ),
      BayaGlassRole.user => (
        colors.userBubble,
        colors.userBubble,
        colors.userBubble,
        0.0,
        6.0,
        2.0,
      ),
      BayaGlassRole.overlay => (
        colors.glassFillStrong.withValues(alpha: dark ? 0.38 : 0.64),
        colors.glassFill.withValues(alpha: dark ? 0.25 : 0.48),
        colors.glassTint.withValues(alpha: dark ? 0.26 : 0.28),
        30.0,
        24.0,
        6.0,
      ),
      BayaGlassRole.brand => (
        colors.inputFill,
        colors.inputFill,
        colors.inputFill,
        0.0,
        12.0,
        3.0,
      ),
    };
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: highContrast
            ? role == BayaGlassRole.user
                  ? colors.userBubble
                  : role == BayaGlassRole.content
                  ? colors.codeBg
                  : role == BayaGlassRole.brand
                  ? colors.inputFill
                  : colors.surface
            : usesBlur
            ? null
            : role == BayaGlassRole.user
            ? colors.userBubble
            : role == BayaGlassRole.content
            ? colors.codeBg
            : role == BayaGlassRole.brand
            ? colors.inputFill
            : colors.surface,
        gradient: usesBlur
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0, 0.48, 1],
                colors: [topFill, tint, bottomFill],
              )
            : null,
        borderRadius: corners,
        border: Border.all(
          color: highContrast
              ? colors.muted2
              : emphasized
              ? resolvedEmphasisColor.withValues(alpha: 0.52)
              : usesBlur
              ? colors.glassEdge
              : role == BayaGlassRole.user
              ? colors.userBubble
              : colors.border.withValues(alpha: .52),
          width: highContrast
              ? 1.2
              : emphasized
              ? 0.9
              : usesBlur
              ? 0.7
              : 0.5,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            if (usesBlur)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: corners,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          colors.glassHighlight.withValues(
                            alpha: colors.glassHighlight.a * 0.20,
                          ),
                          colors.glassHighlight.withValues(alpha: 0),
                        ],
                        stops: const [0, 0.32],
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
            if (usesBlur)
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
                if (usesBlur)
                  BoxShadow(
                    color: colors.glassContactShadow,
                    blurRadius: 4,
                    spreadRadius: -1,
                    offset: const Offset(0, 1),
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
        child: usesBlur
            ? BackdropFilter(
                filter: ui.ImageFilter.blur(
                  sigmaX: blurSigma ?? sigma,
                  sigmaY: blurSigma ?? sigma,
                ),
                child: surface,
              )
            : surface,
      ),
    );
  }
}

/// A clear, two-tier action.
///
/// Primary actions use the solid system accent. Secondary actions use a quiet
/// neutral fill with a hairline edge. Both retain [FilledButton] semantics,
/// focus behavior and platform hit targets without stacking another glass
/// surface inside a glass sheet.
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: prominent && enabled
              ? [
                  BoxShadow(
                    color: colors.accent.withValues(alpha: .20),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: FilledButton(
          key: buttonKey,
          onPressed: onPressed,
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(minimumSize),
            padding: WidgetStatePropertyAll(padding),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return prominent
                    ? colors.accent.withValues(alpha: .34)
                    : colors.inputFill.withValues(alpha: .62);
              }
              if (states.contains(WidgetState.pressed)) {
                return prominent
                    ? Color.lerp(colors.accent, colors.onAccent, .08)!
                    : colors.border.withValues(alpha: .34);
              }
              return prominent ? colors.accent : colors.inputFill;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) return colors.muted;
              return prominent ? colors.onAccent : colors.text;
            }),
            overlayColor: WidgetStatePropertyAll(
              (prominent ? colors.onAccent : colors.accent).withValues(
                alpha: .10,
              ),
            ),
            elevation: const WidgetStatePropertyAll(0),
            shadowColor: const WidgetStatePropertyAll(Colors.transparent),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            side: WidgetStatePropertyAll<BorderSide?>(
              prominent
                  ? BorderSide.none
                  : BorderSide(
                      color: colors.border.withValues(alpha: .58),
                      width: .5,
                    ),
            ),
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
