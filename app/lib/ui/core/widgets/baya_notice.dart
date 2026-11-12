import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// FClash-style notice: a centered modal with a title, one line of context and
/// a single confirm button. Every user-facing notification (updates, pairing,
/// session errors, attach/voice hints) goes through here so the app has one
/// consistent alert surface instead of transient snackbars.
Future<void> showBayaNotice(
  BuildContext context, {
  required String title,
  String? message,
  String? confirmLabel,
  String? secondaryLabel,
  IconData? icon,
  VoidCallback? onConfirm,
  VoidCallback? onSecondary,
  bool dismissible = true,
}) {
  return showBayaDialog<void>(
    context: context,
    barrierDismissible: dismissible,
    builder: (dialogContext) {
      final colors = dialogContext.colors;
      return Dialog(
        key: const Key('baya-notice'),
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: BayaSurface(
          role: BayaSurfaceRole.overlay,
          radius: 28,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (icon != null) ...[
                    Center(
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: colors.selection,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, size: 22, color: colors.accent),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: dialogContext.typo.sansBody.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (message != null && message.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: dialogContext.typo.sansBody.copyWith(
                        fontSize: 13.5,
                        height: 1.5,
                        color: colors.muted2,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  BayaButton(
                    buttonKey: const Key('baya-notice-confirm'),
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                      onConfirm?.call();
                    },
                    label: Text(confirmLabel ?? context.l10n.confirm),
                    minimumSize: const Size.fromHeight(46),
                  ),
                  if (secondaryLabel != null) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      key: const Key('baya-notice-secondary'),
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        onSecondary?.call();
                      },
                      child: Text(secondaryLabel),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Convenience for the most common case: a short, non-blocking-feeling error.
Future<void> showBayaError(BuildContext context, {required String message}) =>
    showBayaNotice(
      context,
      title: context.l10n.somethingWentWrong,
      message: message,
      icon: LucideIcons.circleAlert,
    );
