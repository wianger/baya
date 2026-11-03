import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What to attach to the next prompt.
enum AttachSource { camera, gallery, file }

/// Camera, photos (when the agent takes images) or a file from the session's
/// folder. Closes if the tablet switches to another session meanwhile.
Future<AttachSource?> showAttachSheet(
  BuildContext context, {
  bool images = true,
}) {
  return showBayaSheet<AttachSource>(
    context,
    title: context.l10n.attach,
    dismissOnSessionChange: true,
    builder: (sheetContext) {
      void pick(AttachSource source) => Navigator.of(sheetContext).pop(source);
      return BayaGroup(
        children: [
          if (images) ...[
            BayaRow(
              key: const Key('attach-camera'),
              icon: LucideIcons.camera,
              label: context.l10n.camera,
              onTap: () => pick(AttachSource.camera),
            ),
            BayaRow(
              key: const Key('attach-gallery'),
              icon: LucideIcons.image,
              label: context.l10n.photoLibrary,
              onTap: () => pick(AttachSource.gallery),
            ),
          ],
          BayaRow(
            key: const Key('attach-file'),
            icon: LucideIcons.fileCode,
            label: context.l10n.fileFromFolder,
            onTap: () => pick(AttachSource.file),
          ),
        ],
      );
    },
  );
}
