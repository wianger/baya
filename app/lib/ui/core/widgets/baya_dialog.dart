import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';

/// An AlertDialog-compatible Material 3 modal.
///
/// Keeping [AlertDialog] as the returned primitive preserves semantics and
/// tests that identify dialogs by type, while the complete visible surface is
/// rendered by [BayaSurface].
class BayaDialog extends StatelessWidget {
  const BayaDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      contentPadding: EdgeInsets.zero,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: BayaSurface(
          role: BayaSurfaceRole.overlay,
          radius: 28,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DefaultTextStyle.merge(
                  style: context.typo.title.copyWith(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: context.colors.text,
                  ),
                  child: title,
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(padding: EdgeInsets.zero, child: content),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 6,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
