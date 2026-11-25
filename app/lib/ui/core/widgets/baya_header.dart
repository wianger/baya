/// One header for every page, as Claude draws its own: a floating round
/// button at each side, the title centred between them, and the page
/// colour showing through.
library;

import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A floating round button: the corners of every header, and the home's.
class BayaCircleButton extends StatelessWidget {
  const BayaCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 52,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaSurface(
      role: BayaSurfaceRole.floating,
      radius: size / 2,
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(
            icon,
            size: 21,
            color: onPressed == null ? colors.muted : colors.text,
          ),
        ),
      ),
    );
  }
}

/// A button in a header's actions.
class HeaderAction {
  const HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Key? key;
}

/// What the leading button does.
enum HeaderLeading {
  /// Back to the page before (or home).
  back,

  /// Closes a page that rose over another.
  close,

  /// Opens the drawer ([BayaHeader.onLeading]).
  menu,

  /// No button.
  none,
}

class BayaHeader extends StatelessWidget implements PreferredSizeWidget {
  const BayaHeader({
    super.key,
    this.title,
    this.subtitle,
    this.titleWidget,
    this.leading = HeaderLeading.back,
    this.onLeading,
    this.leadingTooltip,
    this.actions = const [],
    this.monoSubtitle = false,
  });

  final String? title;
  final String? subtitle;

  /// In place of [title] and [subtitle].
  final Widget? titleWidget;
  final HeaderLeading leading;

  /// What the leading button does instead of leaving the page.
  final VoidCallback? onLeading;

  /// The leading button's name, when it does more than go back.
  final String? leadingTooltip;
  final List<HeaderAction> actions;
  final bool monoSubtitle;

  static const height = 72.0;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  void _leave(BuildContext context) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final lead = switch (leading) {
      HeaderLeading.none => null,
      HeaderLeading.back => BayaCircleButton(
        key: const Key('header-back'),
        icon: LucideIcons.chevronLeft,
        tooltip: leadingTooltip ?? l10n.back,
        onPressed: onLeading ?? () => _leave(context),
      ),
      HeaderLeading.menu => BayaCircleButton(
        key: const Key('header-menu'),
        icon: LucideIcons.textAlignStart,
        tooltip: l10n.openNavigation,
        onPressed: onLeading,
      ),
      HeaderLeading.close => BayaCircleButton(
        key: const Key('header-close'),
        icon: LucideIcons.x,
        tooltip: l10n.close,
        onPressed: onLeading ?? () => _leave(context),
      ),
    };
    final trail = switch (actions) {
      [] => null,
      [final one] => BayaCircleButton(
        key: one.key,
        icon: one.icon,
        tooltip: one.tooltip,
        onPressed: one.onPressed,
      ),
      _ => BayaSurface(
        role: BayaSurfaceRole.floating,
        radius: 26,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              SizedBox.square(
                dimension: 52,
                child: IconButton(
                  key: action.key,
                  tooltip: action.tooltip,
                  onPressed: action.onPressed,
                  icon: Icon(action.icon, size: 20, color: colors.text),
                ),
              ),
          ],
        ),
      ),
    };
    final heading =
        titleWidget ??
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: context.typo.sansBody.copyWith(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
            if (subtitle case final text? when text.isNotEmpty)
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style:
                    (monoSubtitle
                            ? context.typo.monoSmall
                            : context.typo.sansBody)
                        .copyWith(fontSize: 12, color: colors.muted),
              ),
          ],
        );
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // The title stays centred on the page whatever sits at its sides.
          child: NavigationToolbar(
            // Slots are as tall as the bar: centred, the buttons stay round.
            leading: lead == null ? null : Center(widthFactor: 1, child: lead),
            middle: heading,
            trailing: trail == null
                ? null
                : Center(widthFactor: 1, child: trail),
            middleSpacing: 12,
          ),
        ),
      ),
    );
  }
}
