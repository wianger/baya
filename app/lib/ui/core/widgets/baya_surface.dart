import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_group.dart';
import 'package:flutter/material.dart';

/// What a surface is for. Hierarchy comes from tone, a hairline edge and
/// spacing; only floating overlays cast a (soft) shadow.
enum BayaSurfaceRole {
  navigation,
  card,
  control,
  content,
  user,
  overlay,
  brand,

  /// DeepSeek's floating controls: the page's own colour, a hairline and
  /// a soft shadow (the menu circle, the composer, the search capsule).
  floating,
}

/// A rounded, flat surface with a hairline edge.
class BayaSurface extends StatelessWidget {
  const BayaSurface({
    super.key,
    required this.child,
    this.radius = 16,
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
      // A card is the same as a group: white on a grey page, grey on a
      // white one, never outlined.
      BayaSurfaceRole.card =>
        BayaTintedPage.of(context)
            ? (Theme.of(context).brightness == Brightness.dark
                  ? colors.modelBadgeBg
                  : colors.bg)
            : colors.inputFill,
      BayaSurfaceRole.control => colors.inputFill,
      BayaSurfaceRole.content => colors.codeBg,
      BayaSurfaceRole.user => colors.userBubble,
      BayaSurfaceRole.overlay => colors.surface,
      BayaSurfaceRole.brand => colors.surface,
      BayaSurfaceRole.floating =>
        Theme.of(context).brightness == Brightness.dark
            ? colors.modelBadgeBg
            : colors.bg,
    };
    final hairline = switch (role) {
      BayaSurfaceRole.content ||
      BayaSurfaceRole.overlay ||
      BayaSurfaceRole.brand ||
      BayaSurfaceRole.floating ||
      BayaSurfaceRole.control => true,
      BayaSurfaceRole.card ||
      BayaSurfaceRole.navigation ||
      BayaSurfaceRole.user => false,
    };
    final outline = emphasized
        ? BorderSide(color: emphasisColor ?? colors.accent, width: 1.2)
        : highContrast
        ? BorderSide(color: colors.muted2, width: 1.2)
        : hairline
        ? BorderSide(color: colors.border)
        : BorderSide.none;
    final floating = role == BayaSurfaceRole.floating;
    final shadow =
        !highContrast &&
        (floating || (elevated && role == BayaSurfaceRole.overlay));
    final content = Padding(padding: padding, child: child);
    final material = Material(
      color: fill,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: corners, side: outline),
      child: content,
    );
    if (!shadow) return material;
    // One soft, wide shadow: the overlay floats without a grey halo.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        boxShadow: [
          if (floating)
            BoxShadow(
              color: Colors.black.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? .30
                    : .06,
              ),
              blurRadius: 14,
              offset: const Offset(0, 3),
            )
          else
            BoxShadow(
              color: Colors.black.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? .45
                    : .07,
              ),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
        ],
      ),
      child: material,
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
              Flexible(child: label),
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
