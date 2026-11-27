/// A small window that opens from what was tapped (the chat's header
/// buttons): a floating card under the finger instead of a sheet from the
/// bottom. Tapping outside closes it.
library;

import 'dart:math' as math;

import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/liquid_morph.dart';
import 'package:flutter/material.dart';

Future<T?> showBayaPopover<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  String? subtitle,
  Key? popoverKey,
  double width = 320,
}) {
  final origin = BayaTapOrigin.last;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.l10n.close,
    barrierColor: Colors.black.withValues(alpha: .08),
    pageBuilder: (dialogContext, _, _) => const SizedBox.shrink(),
    transitionBuilder: (dialogContext, animation, _, _) {
      final media = MediaQuery.of(dialogContext);
      final size = media.size;
      final w = math.min(width, size.width - 24);
      // Under the finger, kept on screen; it grows from that corner.
      final tap = origin ?? Offset(size.width - 24, media.padding.top + 48);
      final left = (tap.dx - w + 28).clamp(12.0, size.width - w - 12);
      final top = math.max(media.padding.top + 8, tap.dy + 22);
      final maxHeight = math.max(
        160.0,
        size.height - top - media.padding.bottom - 16,
      );
      final curved = CurvedAnimation(
        parent: animation,
        curve: BayaMotion.enter,
        reverseCurve: BayaMotion.exit,
      );
      final colors = dialogContext.colors;
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: w,
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: .92, end: 1.0).animate(curved),
                alignment: Alignment(
                  ((tap.dx - left) / w * 2 - 1).clamp(-1.0, 1.0),
                  -1,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: Material(
                    type: MaterialType.transparency,
                    child: BayaSurface(
                      key: popoverKey,
                      role: BayaSurfaceRole.floating,
                      radius: 24,
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (title != null) ...[
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: dialogContext.typo.sansBody.copyWith(
                                fontSize: BayaType.callout,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: dialogContext.typo.sansBody.copyWith(
                                  fontSize: BayaType.footnote,
                                  color: colors.muted,
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                          ],
                          Flexible(
                            child: SingleChildScrollView(
                              child: Builder(builder: builder),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
