import 'package:app/data/hosts/session_controller.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Picks files from the session's folder on the computer; each one goes
/// with the next prompt as an ACP resource link the agent can open.
Future<void> showFilePickerSheet(
  BuildContext context,
  SessionController session,
) {
  return showBayaSheet<void>(
    context,
    title: context.l10n.files,
    builder: (_) => _FilePicker(session: session),
  );
}

class _FilePicker extends StatefulWidget {
  const _FilePicker({required this.session});
  final SessionController session;

  @override
  State<_FilePicker> createState() => _FilePickerState();
}

class _FilePickerState extends State<_FilePicker> {
  late Future<Map<String, dynamic>> _listing = widget.session.browseFiles();
  final _picked = <String>{};

  void _open(String? path) =>
      setState(() => _listing = widget.session.browseFiles(path));

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder(
      future: _listing,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final entries = (data?['entries'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final parent = data?['parent'] as String?;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: context.l10n.back,
                  onPressed: parent == null ? null : () => _open(parent),
                  icon: const Icon(LucideIcons.arrowUp, size: 18),
                ),
                Expanded(
                  child: Text(
                    (data?['path'] as String?) ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.monoSmall.copyWith(color: colors.muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (snapshot.connectionState != ConnectionState.done)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (snapshot.hasError)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${snapshot.error}',
                  style: TextStyle(color: colors.error),
                ),
              )
            else if (entries.isNotEmpty)
              BayaGroup(
                children: [
                  for (final entry in entries)
                    BayaRow(
                      key: ValueKey('file-${entry['name']}'),
                      icon: entry['type'] == 'directory'
                          ? LucideIcons.folder
                          : LucideIcons.file,
                      label: entry['name'] as String,
                      chevron: entry['type'] == 'directory',
                      selected: _picked.contains(entry['path']),
                      onTap: () {
                        final path = entry['path'] as String;
                        if (entry['type'] == 'directory') return _open(path);
                        setState(() {
                          if (_picked.add(path)) {
                            widget.session.attachFile(
                              path,
                              entry['name'] as String,
                            );
                          }
                        });
                      },
                    ),
                ],
              ),
            const SizedBox(height: 14),
            FilledButton(
              key: const Key('file-picker-done'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                _picked.isEmpty
                    ? context.l10n.close
                    : context.l10n.attachCount(_picked.length),
              ),
            ),
          ],
        );
      },
    );
  }
}
