import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_dialog.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';

/// Names a session on its computer: every device shows the name, and no
/// title the agent or Baya makes replaces it. Null when cancelled or empty.
Future<String?> showSessionRenameDialog(
  BuildContext context, {
  required String currentName,
}) async {
  final name = await showNameDialog(
    context,
    title: context.l10n.renameConversation,
    currentValue: currentName,
    hintText: context.l10n.sessionNameEverywhere,
  );
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Future<String?> showDeviceRenameDialog(
  BuildContext context, {
  required String currentName,
}) => showNameDialog(
  context,
  title: context.l10n.renameDevice,
  currentValue: currentName,
  hintText: context.l10n.nameShownInApp,
);

Future<String?> showWorkspaceRenameDialog(
  BuildContext context, {
  required String currentName,
}) => showNameDialog(
  context,
  title: context.l10n.renameWorkspace,
  currentValue: currentName,
  hintText: context.l10n.nameShownInApp,
);

Future<bool> showDeviceDeleteDialog(
  BuildContext context, {
  required String name,
}) async {
  final confirmed = await showBayaDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final colors = dialogContext.colors;
      return BayaDialog(
        title: Text(context.l10n.deleteNamed(name)),
        content: Text(
          context.l10n.deleteDeviceBody,
          style: TextStyle(color: colors.muted2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              context.l10n.delete,
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

Future<bool> showWorkspaceDeleteDialog(
  BuildContext context, {
  required String name,
}) async {
  final confirmed = await showBayaDialog<bool>(
    context: context,
    builder: (dialogContext) => BayaDialog(
      title: Text(context.l10n.deleteWorkspaceNamed(name)),
      content: Text(
        context.l10n.deleteWorkspaceBody,
        style: TextStyle(color: dialogContext.colors.muted2),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(context.l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            context.l10n.delete,
            style: TextStyle(color: dialogContext.colors.error),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

Future<String?> showNameDialog(
  BuildContext context, {
  required String title,
  required String currentValue,
  required String hintText,
}) => showBayaDialog<String?>(
  context: context,
  builder: (_) =>
      _NameDialog(title: title, currentValue: currentValue, hintText: hintText),
);

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.currentValue,
    required this.hintText,
  });

  final String title;
  final String currentValue;
  final String hintText;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentValue)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.currentValue.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BayaDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(hintText: widget.hintText),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.l10n.cancel),
      ),
      BayaButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        label: Text(context.l10n.save),
      ),
    ],
  );
}
