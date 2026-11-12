import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What a session is and what can be done with it, from the chat's ⋯ and
/// the session list alike. Deleting is confirmed inside the sheet.
Future<void> showSessionSheet(
  BuildContext context, {
  required String title,
  required String agent,
  required String computer,
  required String? folder,
  bool pinned = false,
  ValueChanged<bool>? onPin,
  VoidCallback? onFind,
  VoidCallback? onFiles,
  VoidCallback? onChanges,
  VoidCallback? onPreview,
  required VoidCallback onRename,
  required Future<void> Function() onDelete,
}) {
  return showBayaSheet<void>(
    context,
    sheetKey: const Key('session-sheet'),
    title: title,
    subtitle: '$agent · $computer',
    builder: (_) => _SessionSheet(
      title: title,
      agent: agent,
      computer: computer,
      folder: folder,
      pinned: pinned,
      onPin: onPin,
      onFind: onFind,
      onFiles: onFiles,
      onChanges: onChanges,
      onPreview: onPreview,
      onRename: onRename,
      onDelete: onDelete,
    ),
  );
}

class _SessionSheet extends StatefulWidget {
  const _SessionSheet({
    required this.title,
    required this.agent,
    required this.computer,
    required this.folder,
    required this.pinned,
    required this.onPin,
    required this.onFind,
    required this.onFiles,
    required this.onChanges,
    required this.onPreview,
    required this.onRename,
    required this.onDelete,
  });

  final String title;
  final String agent;
  final String computer;
  final String? folder;
  final bool pinned;
  final ValueChanged<bool>? onPin;
  final VoidCallback? onFind;
  final VoidCallback? onFiles;
  final VoidCallback? onChanges;
  final VoidCallback? onPreview;
  final VoidCallback onRename;
  final Future<void> Function() onDelete;

  @override
  State<_SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends State<_SessionSheet> {
  bool _confirming = false;
  bool _deleting = false;
  String? _error;

  void _then(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await widget.onDelete();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _deleting = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.folder case final folder? when folder.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: SelectableText(
              folder,
              maxLines: 2,
              style: context.typo.monoSmall.copyWith(
                fontSize: 12,
                color: colors.muted,
              ),
            ),
          ),
        BayaGroup(
          children: [
            if (widget.onFind case final find?)
              BayaRow(
                key: const ValueKey('session-action-find'),
                icon: LucideIcons.search,
                label: l10n.findInChat,
                onTap: () => _then(find),
              ),
            if (widget.onChanges case final changes?)
              BayaRow(
                key: const ValueKey('session-action-changes'),
                icon: LucideIcons.gitCompareArrows,
                label: l10n.changes,
                chevron: true,
                onTap: () => _then(changes),
              ),
            if (widget.onPreview case final preview?)
              BayaRow(
                key: const ValueKey('session-action-preview'),
                icon: LucideIcons.globe,
                label: l10n.webPreview,
                subtitle: l10n.webPreviewHint,
                chevron: true,
                onTap: () => _then(preview),
              ),
            if (widget.onFiles case final files?)
              BayaRow(
                key: const ValueKey('session-action-files'),
                icon: LucideIcons.folderOpen,
                label: l10n.files,
                chevron: true,
                onTap: () => _then(files),
              ),
            if (widget.onPin case final pin?)
              BayaRow(
                key: const ValueKey('session-action-pin'),
                icon: widget.pinned ? LucideIcons.pinOff : LucideIcons.pin,
                label: widget.pinned ? l10n.unpinSession : l10n.pinSession,
                onTap: () => _then(() => pin(!widget.pinned)),
              ),
            BayaRow(
              key: const ValueKey('session-action-rename'),
              icon: LucideIcons.pencil,
              label: l10n.rename,
              onTap: () => _then(widget.onRename),
            ),
          ],
        ),
        const SizedBox(height: 10),
        AnimatedSize(
          duration: BayaMotion.standard,
          curve: BayaMotion.enter,
          alignment: Alignment.topCenter,
          child: BayaGroup(
            danger: _confirming,
            children: [
              if (!_confirming)
                BayaRow(
                  key: const ValueKey('session-action-delete'),
                  icon: LucideIcons.trash2,
                  label: l10n.deleteSession,
                  destructive: true,
                  onTap: () => setState(() => _confirming = true),
                )
              else
                Padding(
                  key: const Key('session-delete-confirm'),
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.deleteSessionBody(widget.title),
                        style: context.typo.sansBody.copyWith(
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                      if (_error case final error?) ...[
                        const SizedBox(height: 8),
                        Text(
                          error,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 13,
                            color: colors.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _deleting
                                  ? null
                                  : () => setState(() => _confirming = false),
                              child: Text(l10n.cancel),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              key: const Key('session-delete-confirm-button'),
                              style: FilledButton.styleFrom(
                                backgroundColor: colors.error,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _deleting ? null : _delete,
                              child: _deleting
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.8,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(l10n.delete),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
