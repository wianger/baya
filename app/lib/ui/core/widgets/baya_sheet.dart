import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/dismiss_on_session_change.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

export 'package:app/ui/core/widgets/baya_group.dart';

/// Every bottom sheet in the app: one surface, handle, header and spacing.
/// [builder] gives the body; it scrolls inside the sheet when it is taller
/// than [maxHeight] of the screen, and the sheet rises with the keyboard.
Future<T?> showBayaSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  String? subtitle,
  Widget? action,
  Key? sheetKey,
  double maxHeight = .86,
  bool dismissOnSessionChange = false,
}) {
  final selection = dismissOnSessionChange
      ? context.read<SessionSelection>()
      : null;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .4),
    sheetAnimationStyle: const AnimationStyle(
      duration: BayaMotion.standard,
      curve: BayaMotion.enter,
    ),
    builder: (sheetContext) {
      Widget sheet = BayaSheet(
        key: sheetKey,
        title: title,
        subtitle: subtitle,
        action: action,
        maxHeight: maxHeight,
        child: Builder(builder: builder),
      );
      if (selection != null) {
        sheet = DismissOnSessionChange(selection: selection, child: sheet);
      }
      return sheet;
    },
  );
}

class BayaSheet extends StatelessWidget {
  const BayaSheet({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.action,
    this.maxHeight = .86,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final Widget? action;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * maxHeight),
        child: BayaSurface(
          role: BayaSurfaceRole.overlay,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          elevated: false,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  SizedBox(height: title == null ? 10 : 16),
                  if (title != null) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title!,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -.3,
                            ),
                          ),
                        ),
                        if (action != null) ...[
                          const SizedBox(width: 12),
                          action!,
                        ],
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 13,
                          height: 1.4,
                          color: colors.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                  ],
                  Flexible(child: SingleChildScrollView(child: child)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
