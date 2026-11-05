import 'package:app/domain/entities/update_info.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_dialog.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';

/// Tells about a newer release when the app opens: its version and notes,
/// to download now or later (this version is then not asked about again).
Future<void> showUpdatePrompt(
  BuildContext context,
  UpdateBannerViewModel updates,
  UpdateInfo info,
) {
  return showBayaDialog<void>(
    context: context,
    builder: (dialogContext) {
      final colors = dialogContext.colors;
      final notes = info.notes.trim();
      return BayaDialog(
        key: const Key('update-prompt'),
        title: Text(dialogContext.l10n.updateOut(info.version)),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (notes.isNotEmpty) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: Text(
                    notes,
                    style: dialogContext.typo.sansBody.copyWith(
                      color: colors.muted2,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              dialogContext.l10n.updateKeepsDataAndroid,
              style: dialogContext.typo.sansBody.copyWith(
                color: colors.muted,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('update-later'),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              updates.dismiss();
            },
            child: Text(dialogContext.l10n.later),
          ),
          FilledButton(
            key: const Key('update-download'),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final opened = await updates.download();
              if (opened || !context.mounted) return;
              await showBayaNotice(
                context,
                title: context.l10n.couldNotOpenLink,
                message: context.l10n.checkConnectionTryAgain,
              );
            },
            child: Text(dialogContext.l10n.downloadApk),
          ),
        ],
      );
    },
  );
}
