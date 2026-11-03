import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Pair by pasting the code as text, for when the camera can't read the QR.
/// [onSubmit] receives the `baya://pair?…` text once the sheet has closed;
/// the caller reports a bad code the same way a scan would.
Future<void> showPasteQrSheet(
  BuildContext context, {
  required void Function(String raw) onSubmit,
}) {
  return showBayaSheet<void>(
    context,
    title: context.l10n.pastePairingCode,
    subtitle: context.l10n.pasteCodeHint,
    builder: (_) => _PasteQrBody(onSubmit: onSubmit),
  );
}

class _PasteQrBody extends StatefulWidget {
  const _PasteQrBody({required this.onSubmit});
  final void Function(String raw) onSubmit;

  @override
  State<_PasteQrBody> createState() => _PasteQrBodyState();
}

class _PasteQrBodyState extends State<_PasteQrBody> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    });
  }

  void _submit() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    Navigator.of(context).pop();
    widget.onSubmit(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          minLines: 3,
          maxLines: 6,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {}),
          style: context.typo.mono.copyWith(fontSize: 12.5),
          decoration: const InputDecoration(hintText: 'baya://pair?t=…'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _paste,
          icon: const Icon(LucideIcons.clipboardPaste, size: 16),
          label: Text(context.l10n.pasteFromClipboard),
        ),
        const SizedBox(height: 10),
        BayaButton(
          onPressed: _controller.text.trim().isEmpty ? null : _submit,
          label: Text(context.l10n.pair),
          minimumSize: const Size.fromHeight(50),
        ),
      ],
    );
  }
}
