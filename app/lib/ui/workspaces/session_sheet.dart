import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
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
  VoidCallback? onFiles,
  required VoidCallback onRename,
  required Future<void> Function() onDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .38),
    sheetAnimationStyle: AnimationStyle(
      duration: BayaMotion.standard,
      curve: BayaMotion.enter,
    ),
    builder: (_) => _SessionSheet(
      title: title,
      agent: agent,
      computer: computer,
      folder: folder,
      onFiles: onFiles,
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
    required this.onFiles,
    required this.onRename,
    required this.onDelete,
  });

  final String title;
  final String agent;
  final String computer;
  final String? folder;
  final VoidCallback? onFiles;
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
    return SafeArea(
      top: false,
      child: BayaSurface(
        key: const Key('session-sheet'),
        role: BayaSurfaceRole.overlay,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 16, 6, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.agent} · ${widget.computer}',
                    style: context.typo.sansBody.copyWith(
                      fontSize: 13,
                      color: colors.muted2,
                    ),
                  ),
                  if (widget.folder case final folder? when folder.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: SelectableText(
                        folder,
                        maxLines: 2,
                        style: context.typo.monoSmall.copyWith(
                          fontSize: 12,
                          color: colors.muted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            _Group(
              children: [
                if (widget.onFiles case final files?)
                  _Action(
                    key: const ValueKey('session-action-files'),
                    icon: LucideIcons.folderOpen,
                    label: l10n.files,
                    chevron: true,
                    onTap: () => _then(files),
                  ),
                _Action(
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
              child: _Group(
                danger: _confirming,
                children: [
                  if (!_confirming)
                    _Action(
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
                                      : () =>
                                            setState(() => _confirming = false),
                                  child: Text(l10n.cancel),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton(
                                  key: const Key(
                                    'session-delete-confirm-button',
                                  ),
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
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children, this.danger = false});

  final List<Widget> children;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: danger ? colors.error.withValues(alpha: .08) : colors.inputFill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: danger ? colors.error.withValues(alpha: .35) : colors.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 48, color: colors.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.chevron = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tint = destructive ? colors.error : colors.text;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Icon(icon, size: 18, color: destructive ? tint : colors.muted2),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: context.typo.sansBody.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: tint,
                ),
              ),
            ),
            if (chevron)
              Icon(LucideIcons.chevronRight, size: 16, color: colors.muted),
          ],
        ),
      ),
    );
  }
}
