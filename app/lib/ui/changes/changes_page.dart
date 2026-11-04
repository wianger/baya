import 'package:app/data/hosts/session_controller.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/code/code_view.dart';
import 'package:app/ui/core/code/highlighter.dart';
import 'package:app/ui/core/code/line_diff.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// What the agent changed in the session's repository: review each file,
/// revert what is wrong, then commit, push and open a pull request.
Future<void> openChanges(BuildContext context, SessionController session) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChangesPage(session: session)),
    );

class ChangesPage extends StatefulWidget {
  const ChangesPage({super.key, required this.session});
  final SessionController session;

  @override
  State<ChangesPage> createState() => _ChangesPageState();
}

class _ChangesPageState extends State<ChangesPage> {
  late Future<Map<String, dynamic>> _status = widget.session.gitStatus();
  final _message = TextEditingController();
  String? _busy;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _reload() => setState(() {
    _status = widget.session.gitStatus();
  });

  Future<void> _run(String what, Future<void> Function() action) async {
    setState(() => _busy = what);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        await showBayaNotice(
          context,
          title: context.l10n.error,
          message: '$error',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = null);
        _reload();
      }
    }
  }

  Future<void> _commit() => _run('commit', () async {
    final result = await widget.session.gitCommit(_message.text.trim());
    _message.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.committed('${result['commit']}'))),
      );
    }
  });

  Future<void> _push() => _run('push', () async {
    await widget.session.gitPush();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.pushed)));
    }
  });

  Future<void> _pullRequest() async {
    final details = await showBayaSheet<(String, String)>(
      context,
      title: context.l10n.openPullRequest,
      builder: (_) => const _PullRequestForm(),
    );
    if (details == null || !mounted) return;
    await _run('pr', () async {
      final result = await widget.session.openPullRequest(
        details.$1,
        details.$2,
      );
      final url = Uri.tryParse('${result['url']}');
      if (url != null && url.hasScheme) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        title: Text(context.l10n.changes),
        actions: [
          IconButton(
            tooltip: context.l10n.refresh,
            onPressed: _busy == null ? _reload : null,
            icon: const Icon(LucideIcons.refreshCw, size: 19),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _status,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted2),
                ),
              ),
            );
          }
          final status = snapshot.data!;
          final files = (status['files'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          final ahead = status['ahead'] as int? ?? 0;
          final upstream = status['upstream'] as String?;
          return ListView(
            key: const Key('changes-list'),
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
            children: [
              Row(
                children: [
                  Icon(LucideIcons.gitBranch, size: 16, color: colors.muted2),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      [
                        '${status['branch']}',
                        ?upstream,
                        if (ahead > 0) context.l10n.commitsAhead(ahead),
                      ].join(' · '),
                      style: context.typo.monoSmall.copyWith(
                        color: colors.muted2,
                      ),
                    ),
                  ),
                ],
              ),
              BayaSectionLabel(
                context.l10n.changedFiles(files.length),
                top: 22,
              ),
              if (files.isEmpty)
                Text(
                  context.l10n.noChanges,
                  style: context.typo.sansBody.copyWith(color: colors.muted),
                )
              else ...[
                BayaGroup(
                  children: [
                    for (final file in files)
                      BayaRow(
                        key: ValueKey('change-${file['path']}'),
                        icon: switch (file['status']) {
                          'A' || '?' => LucideIcons.filePlus,
                          'D' => LucideIcons.fileMinus,
                          _ => LucideIcons.fileDiff,
                        },
                        label: '${file['path']}'.split('/').last,
                        subtitle: '${file['path']}',
                        monospaceSubtitle: true,
                        trailing: _Counts(
                          added: file['added'] as int? ?? 0,
                          removed: file['removed'] as int? ?? 0,
                          fresh: file['status'] == '?',
                        ),
                        chevron: true,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _FileChanges(
                                session: widget.session,
                                path: '${file['path']}',
                              ),
                            ),
                          );
                          _reload();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  key: const Key('commit-message'),
                  controller: _message,
                  minLines: 1,
                  maxLines: 4,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: context.l10n.commitMessageHint,
                  ),
                ),
                const SizedBox(height: 10),
                BayaButton(
                  key: const Key('commit'),
                  onPressed: _busy == null && _message.text.trim().isNotEmpty
                      ? _commit
                      : null,
                  icon: _busy == 'commit'
                      ? const _Spinner()
                      : const Icon(LucideIcons.gitCommitHorizontal, size: 18),
                  label: Text(context.l10n.commitAll(files.length)),
                  minimumSize: const Size.fromHeight(50),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('push'),
                      onPressed:
                          _busy == null && (ahead > 0 || upstream == null)
                          ? _push
                          : null,
                      icon: _busy == 'push'
                          ? const _Spinner()
                          : const Icon(LucideIcons.upload, size: 16),
                      label: Text(context.l10n.push),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('pull-request'),
                      onPressed: _busy == null ? _pullRequest : null,
                      icon: _busy == 'pr'
                          ? const _Spinner()
                          : const Icon(LucideIcons.gitPullRequest, size: 16),
                      label: Text(context.l10n.pullRequest),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 1.8),
  );
}

class _Counts extends StatelessWidget {
  const _Counts({
    required this.added,
    required this.removed,
    required this.fresh,
  });

  final int added;
  final int removed;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = context.typo.monoSmall.copyWith(fontSize: 11.5);
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: fresh
          ? Text(
              context.l10n.newFile,
              style: style.copyWith(color: colors.success),
            )
          : Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '+$added ',
                    style: style.copyWith(color: colors.success),
                  ),
                  TextSpan(
                    text: '−$removed',
                    style: style.copyWith(color: colors.error),
                  ),
                ],
              ),
            ),
    );
  }
}

class _PullRequestForm extends StatefulWidget {
  const _PullRequestForm();

  @override
  State<_PullRequestForm> createState() => _PullRequestFormState();
}

class _PullRequestFormState extends State<_PullRequestForm> {
  final _title = TextEditingController();
  final _body = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('pr-title'),
          controller: _title,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(hintText: context.l10n.pullRequestTitle),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _body,
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(hintText: context.l10n.pullRequestBody),
        ),
        const SizedBox(height: 14),
        BayaButton(
          key: const Key('pr-create'),
          onPressed: _title.text.trim().isEmpty
              ? null
              : () =>
                    Navigator.of(context)
                        .pop((_title.text.trim(), _body.text.trim())),
          label: Text(context.l10n.openPullRequest),
          minimumSize: const Size.fromHeight(50),
        ),
      ],
    );
  }
}

/// One file's changes, hunk by hunk, each with its own Revert.
class _FileChanges extends StatefulWidget {
  const _FileChanges({required this.session, required this.path});
  final SessionController session;
  final String path;

  @override
  State<_FileChanges> createState() => _FileChangesState();
}

class _FileChangesState extends State<_FileChanges> {
  late Future<Map<String, dynamic>> _diff = widget.session.gitDiff(widget.path);
  int? _confirming;
  bool _busy = false;

  Future<void> _revert({int? hunk}) async {
    setState(() => _busy = true);
    try {
      await widget.session.gitRevert(widget.path, hunk: hunk);
      if (!mounted) return;
      if (hunk == null) return Navigator.of(context).pop();
      setState(() {
        _confirming = null;
        _diff = widget.session.gitDiff(widget.path);
      });
    } catch (error) {
      if (mounted) {
        await showBayaNotice(
          context,
          title: context.l10n.error,
          message: '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revertFile() async {
    final confirmed = await showBayaSheet<bool>(
      context,
      title: context.l10n.revertFileTitle,
      subtitle: context.l10n.revertFileBody(widget.path),
      builder: (sheetContext) => BayaGroup(
        danger: true,
        children: [
          BayaRow(
            key: const Key('revert-file-confirm'),
            icon: LucideIcons.undo2,
            label: context.l10n.revertFile,
            destructive: true,
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed == true) await _revert();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final language = CodeHighlighter.languageForPath(widget.path);
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        title: Text(widget.path.split('/').last),
        actions: [
          IconButton(
            key: const Key('revert-file'),
            tooltip: context.l10n.revertFile,
            onPressed: _busy ? null : _revertFile,
            icon: const Icon(LucideIcons.undo2, size: 19),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _diff,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (snapshot.hasError) {
            return Center(child: Text('${snapshot.error}'));
          }
          final hunks = (snapshot.data!['hunks'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          if (hunks.isEmpty) {
            return Center(
              child: Text(
                context.l10n.noChanges,
                style: TextStyle(color: colors.muted),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
            itemCount: hunks.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Text(
                  widget.path,
                  style: context.typo.monoSmall.copyWith(color: colors.muted),
                );
              }
              final i = index - 1;
              final lines = gitHunkLines(hunks[i]);
              final first = lines.firstOrNull;
              final confirming = _confirming == i;
              return BayaSurface(
                key: ValueKey('hunk-$i'),
                role: BayaSurfaceRole.content,
                radius: 12,
                elevated: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.l10n.fromLine(
                                first?.newNumber ?? first?.oldNumber ?? 1,
                              ),
                              style: context.typo.monoSmall.copyWith(
                                fontSize: 11,
                                color: colors.muted,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            key: ValueKey('revert-hunk-$i'),
                            onPressed: _busy
                                ? null
                                : confirming
                                ? () => _revert(hunk: i)
                                : () => setState(() => _confirming = i),
                            style: TextButton.styleFrom(
                              foregroundColor: confirming
                                  ? colors.error
                                  : colors.muted2,
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(LucideIcons.undo2, size: 15),
                            label: Text(
                              confirming
                                  ? context.l10n.confirmRevert
                                  : context.l10n.revert,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: HunkLines(hunks: [lines], language: language),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// A hunk from the computer's git diff as numbered diff lines.
List<DiffLine> gitHunkLines(Map<String, dynamic> hunk) {
  var oldNo = hunk['oldStart'] as int? ?? 1;
  var newNo = hunk['newStart'] as int? ?? 1;
  return [
    for (final line
        in (hunk['lines'] as List? ?? const []).cast<Map<String, dynamic>>())
      switch (line['kind']) {
        '+' => DiffLine(DiffKind.added, '${line['text']}', newNumber: newNo++),
        '-' => DiffLine(
          DiffKind.removed,
          '${line['text']}',
          oldNumber: oldNo++,
        ),
        _ => DiffLine(
          DiffKind.context,
          '${line['text']}',
          oldNumber: oldNo++,
          newNumber: newNo++,
        ),
      },
  ];
}
