import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';

/// What a surface is for. Each role maps to one Material 3 tonal container,
/// so hierarchy comes from tone and spacing instead of blur and shadows.
enum BayaSurfaceRole {
  navigation,
  card,
  control,
  content,
  user,
  overlay,
  brand,
}

/// A rounded Material 3 tonal surface.
class BayaSurface extends StatelessWidget {
  const BayaSurface({
    super.key,
    required this.child,
    this.radius = 28,
    this.borderRadius,
    this.padding = EdgeInsets.zero,
    this.elevated = true,
    this.emphasized = false,
    this.emphasisColor,
    this.role = BayaSurfaceRole.card,
  });

  final Widget child;
  final double radius;
  final BorderRadiusGeometry? borderRadius;
  final EdgeInsetsGeometry padding;

  /// Floating overlays (menus, popovers) cast the M3 level-2 shadow.
  final bool elevated;
  final bool emphasized;
  final Color? emphasisColor;
  final BayaSurfaceRole role;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final highContrast = MediaQuery.maybeOf(context)?.highContrast ?? false;
    final corners = borderRadius ?? BorderRadius.circular(radius);
    final fill = switch (role) {
      BayaSurfaceRole.navigation => colors.codeBg,
      BayaSurfaceRole.card => colors.surface,
      BayaSurfaceRole.control => colors.inputFill,
      BayaSurfaceRole.content => colors.codeBg,
      BayaSurfaceRole.user => colors.userBubble,
      BayaSurfaceRole.overlay => colors.inputFill,
      BayaSurfaceRole.brand => colors.surface,
    };
    final outline = emphasized
        ? BorderSide(color: emphasisColor ?? colors.accent, width: 1.5)
        : highContrast
        ? BorderSide(color: colors.muted2, width: 1.2)
        : BorderSide.none;
    final shadow = elevated && !highContrast && role == BayaSurfaceRole.overlay;
    final contentMotion = BayaSurfaceContentMotion.surfaceOf(context);
    final content = Padding(padding: padding, child: child);
    return Material(
      color: fill,
      elevation: shadow ? 3 : 0,
      shadowColor: colors.glassShadow,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: corners, side: outline),
      child: contentMotion == null
          ? content
          : AnimatedBuilder(
              animation: Listenable.merge([
                contentMotion.animation,
                ?contentMotion.surfaceScale,
              ]),
              child: content,
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
    );
  }
}

/// Primary actions are filled; secondary actions are tonal.
class BayaButton extends StatelessWidget {
  const BayaButton({
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
    final style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(minimumSize),
      padding: WidgetStatePropertyAll(padding),
    );
    final child = icon == null
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
          );
    return prominent
        ? FilledButton(
            key: buttonKey,
            onPressed: onPressed,
            style: style,
            child: child,
          )
        : FilledButton.tonal(
            key: buttonKey,
            onPressed: onPressed,
            style: style,
            child: child,
          );
  }
}
