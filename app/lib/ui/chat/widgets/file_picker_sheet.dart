import 'package:app/data/hosts/session_controller.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Picks files from the session's folder on the computer; each one goes
/// with the next prompt as an ACP resource link the agent can open.
Future<void> showFilePickerSheet(
  BuildContext context,
  SessionController session,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle(
      duration: BayaMotion.standard,
      curve: BayaMotion.enter,
    ),
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
    final mq = MediaQuery.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * .78),
        child: BayaSurface(
          role: BayaSurfaceRole.overlay,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: FutureBuilder(
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
                        icon: const Icon(LucideIcons.arrowUp, size: 19),
                      ),
                      Expanded(
                        child: Text(
                          (data?['path'] as String?) ?? context.l10n.files,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.monoSmall,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilledButton(
                          key: const Key('file-picker-done'),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(
                            _picked.isEmpty
                                ? context.l10n.close
                                : context.l10n.attachCount(_picked.length),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Divider(color: colors.border),
                  if (snapshot.connectionState != ConnectionState.done)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (snapshot.hasError)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        '${snapshot.error}',
                        style: TextStyle(color: colors.error),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final entry in entries)
                            _Entry(
                              name: entry['name'] as String,
                              directory: entry['type'] == 'directory',
                              picked: _picked.contains(entry['path']),
                              onTap: () {
                                final path = entry['path'] as String;
                                if (entry['type'] == 'directory') {
                                  return _open(path);
                                }
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
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.name,
    required this.directory,
    required this.picked,
    required this.onTap,
  });

  final String name;
  final bool directory;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListTile(
      key: ValueKey('file-$name'),
      dense: true,
      leading: Icon(
        directory ? LucideIcons.folder : LucideIcons.file,
        size: 18,
        color: directory ? colors.muted2 : colors.muted,
      ),
      title: Text(name, style: context.typo.mono.copyWith(fontSize: 13)),
      trailing: directory
          ? Icon(LucideIcons.chevronRight, size: 16, color: colors.muted)
          : picked
          ? Icon(LucideIcons.check, size: 17, color: colors.accent)
          : null,
      onTap: onTap,
    );
  }
}
