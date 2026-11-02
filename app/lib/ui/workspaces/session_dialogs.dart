import 'package:app/pairing/storage.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_dialog.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:flutter/material.dart';

/// Phone-local conversation rename. Empty input clears the override so the
/// computer's announced room name is shown again.
Future<String?> showSessionRenameDialog(
  BuildContext context, {
  required String currentName,
}) => showNameDialog(
  context,
  title: context.l10n.renameConversation,
  currentValue: currentName,
  hintText: context.l10n.leaveEmptyForComputerName,
);

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
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final colors = dialogContext.colors;
      return BayaGlassDialog(
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
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => BayaGlassDialog(
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

Future<bool> showSessionDeleteDialog(
  BuildContext context, {
  required String name,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => BayaGlassDialog(
      title: Text(context.l10n.deleteFromPhone),
      content: Text(context.l10n.deleteSessionBody(name)),
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
}) => showDialog<String?>(
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
  Widget build(BuildContext context) => BayaGlassDialog(
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
      BayaGlassButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        label: Text(context.l10n.save),
      ),
    ],
  );
}

/// Shared by the sidebar action sheet and the chat header menu, so both show
/// the same room, directory, model and device details.
Future<void> showSessionInfoDialog(
  BuildContext context, {
  required PeerRecord peer,
  required RoomInfo? room,
  required String name,
}) {
  final owner = (peer.nickname?.isNotEmpty ?? false)
      ? peer.nickname!
      : peer.sessionName.isNotEmpty
      ? peer.sessionName
      : peer.remoteEpk.substring(0, 8);
  final model = room?.model;
  final paired = peer.pairedAt.contains('T')
      ? peer.pairedAt.split('T').first
      : peer.pairedAt;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return BayaGlassDialog(
        title: Text(context.l10n.sessionInfo, style: dialogContext.typo.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: context.l10n.name, value: name),
            _InfoRow(label: context.l10n.path, value: room?.cwd ?? '—'),
            _InfoRow(label: context.l10n.owner, value: owner),
            if (model != null && model.isNotEmpty)
              _InfoRow(label: context.l10n.model, value: model),
            _InfoRow(label: context.l10n.room, value: room?.roomId ?? '—'),
            _InfoRow(label: context.l10n.paired, value: paired),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.close),
          ),
        ],
      );
    },
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: context.typo.monoSmall.copyWith(color: colors.muted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: context.typo.monoSmall.copyWith(color: colors.text),
            ),
          ),
        ],
      ),
    );
  }
}
