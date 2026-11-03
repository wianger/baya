import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';

/// Post-pair nickname modal.
///
/// Asks the user for a friendly label for the just-paired computer. The
/// caller seeds [defaultName] with the hostname `_baya/pair` returned when present
/// (e.g. "Studio"), or the session name as a softer fallback, or `null`
/// so the field hints with the generic placeholder "Computer".
///
/// Returns the trimmed nickname string the user wants persisted:
/// - "Save" with non-empty input → returns the input.
/// - "Save" with empty input    → behaves as Skip (returns the default).
/// - "Skip"                     → returns [defaultName] ?? "Computer".
/// - Drag-down dismiss          → returns null (caller treats as Skip too).
///
/// Caller is responsible for calling `PeerRecord.copyWith(nickname:)`
/// and writing back to storage.
Future<String?> showNicknameSheet(
  BuildContext context, {
  required String? defaultName,
}) {
  return showBayaSheet<String>(
    context,
    title: context.l10n.nameThisPc,
    subtitle: context.l10n.nicknameHint,
    builder: (_) => _NicknameSheet(defaultName: defaultName),
  );
}

class _NicknameSheet extends StatefulWidget {
  final String? defaultName;
  const _NicknameSheet({required this.defaultName});

  @override
  State<_NicknameSheet> createState() => _NicknameSheetState();
}

class _NicknameSheetState extends State<_NicknameSheet> {
  late final TextEditingController _controller;
  static final _fallback = appL10n.computer;

  String get _placeholder {
    final d = widget.defaultName?.trim();
    return (d == null || d.isEmpty) ? _fallback : d;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final typed = _controller.text.trim();
    Navigator.of(context).pop(typed.isEmpty ? _placeholder : typed);
  }

  void _skip() {
    Navigator.of(context).pop(_placeholder);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('nickname-sheet-field'),
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(hintText: _placeholder),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('nickname-sheet-skip'),
                onPressed: _skip,
                child: Text(context.l10n.skip),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: BayaButton(
                buttonKey: const Key('nickname-sheet-save'),
                onPressed: _save,
                label: Text(context.l10n.save),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
