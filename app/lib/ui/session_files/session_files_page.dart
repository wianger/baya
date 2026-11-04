import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/code/code_view.dart';
import 'package:app/ui/core/widgets/copy_button.dart';
import 'package:app/ui/core/code/highlighter.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/session_files/states/session_files_state.dart';
import 'package:app/ui/session_files/file_preview.dart';
import 'package:app/ui/session_files/viewmodels/session_files_viewmodel.dart';
import 'package:app/ui/transfer/transfer_flow.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class SessionFilesPage extends StatefulWidget {
  const SessionFilesPage({super.key});

  @override
  State<SessionFilesPage> createState() => _SessionFilesPageState();
}

class _SessionFilesPageState extends State<SessionFilesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<SessionFilesViewModel>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SessionFilesViewModel>();
    final state = vm.state;
    final showingFile = state is SessionFilesFile;
    return PopScope(
      canPop: !showingFile,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && showingFile) vm.closeFile();
      },
      child: Scaffold(
        backgroundColor: context.colors.bg,
        body: BayaBackdrop(
          child: SafeArea(
            child: Column(
              children: [
                _FilesHeader(
                  state: state,
                  showHidden: vm.showHidden,
                  onBack: () {
                    if (showingFile) {
                      vm.closeFile();
                    } else {
                      context.pop();
                    }
                  },
                  onRefresh: vm.refresh,
                  onToggleHidden: showingFile ? null : vm.toggleHidden,
                  onUpload: state is SessionFilesDirectory
                      ? () => _upload(vm, state.directory.path)
                      : null,
                  onSave: state is SessionFilesFile
                      ? () => _save(state.file)
                      : null,
                ),
                if (state is SessionFilesLoading && state.previous != null)
                  const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: BayaReveal(
                    offset: 5,
                    child: _buildBody(context, vm, state),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Files between the phone and this session's folder, or null offline.
  FileTransfer? _transfer() {
    final selected = context.read<SessionSelection>().current;
    final host = context.read<Hosts>().byKey(selected?.hostKey);
    if (selected == null || host == null) return null;
    return FileTransfer(HostTransferLink(host, selected.sessionId));
  }

  Future<void> _upload(SessionFilesViewModel vm, String dir) async {
    final transfer = _transfer();
    if (transfer == null) return;
    final sent = await uploadFromPhone(context, transfer, dir: dir);
    if (sent.isEmpty || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(context.l10n.uploadedHere(sent.length))),
    );
    await vm.refresh();
  }

  Future<void> _save(SessionFileContent file) async {
    final transfer = _transfer();
    if (transfer == null) return;
    await saveToPhone(context, transfer, path: file.path, name: file.name);
  }

  Widget _buildBody(
    BuildContext context,
    SessionFilesViewModel vm,
    SessionFilesState state,
  ) {
    if (state is SessionFilesLoading) {
      final previous = state.previous;
      if (previous == null) {
        return const Center(
          child: SizedBox.square(
            dimension: 26,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      return _DirectoryView(
        directory: previous,
        busy: true,
        onOpenDirectory: (path) => vm.browse(path: path),
        onOpenFile: vm.openFile,
      );
    }
    if (state is SessionFilesDirectory) {
      return _DirectoryView(
        directory: state.directory,
        onOpenDirectory: (path) => vm.browse(path: path),
        onOpenFile: vm.openFile,
      );
    }
    if (state is SessionFilesFile) {
      return _FileView(
        file: state.file,
        transfer: previewKindFor(state.file.name) == null ? null : _transfer(),
        onOpenElsewhere: () => _save(state.file),
        onOpenPath: (path, name) => vm.openFile(
          SessionFileEntry(name: name, path: path, kind: SessionFileKind.file),
        ),
      );
    }
    final error = state as SessionFilesError;
    return _ErrorView(
      message: error.message,
      onRetry: error.previous == null
          ? vm.load
          : () => vm.browse(path: error.previous!.path),
    );
  }
}

class _FilesHeader extends StatelessWidget {
  const _FilesHeader({
    required this.state,
    required this.showHidden,
    required this.onBack,
    required this.onRefresh,
    required this.onToggleHidden,
    this.onUpload,
    this.onSave,
  });

  final SessionFilesState state;
  final VoidCallback? onUpload;
  final VoidCallback? onSave;
  final bool showHidden;
  final VoidCallback onBack;
  final Future<void> Function() onRefresh;
  final Future<void> Function()? onToggleHidden;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = switch (state) {
      SessionFilesDirectory(:final directory) => (
        _baseName(directory.root),
        directory.path == directory.root
            ? context.l10n.sessionWorkspace
            : _relativePath(directory.root, directory.path),
      ),
      SessionFilesFile(:final file) => (
        file.name,
        context.l10n.readOnlyFilePreview,
      ),
      SessionFilesError(:final previous) => (
        previous == null ? context.l10n.sessionFiles : _baseName(previous.root),
        previous == null
            ? context.l10n.sessionFolder
            : _relativePath(previous.root, previous.path),
      ),
      SessionFilesLoading(:final previous) => (
        previous == null ? context.l10n.sessionFiles : _baseName(previous.root),
        previous == null
            ? context.l10n.sessionFolder
            : _relativePath(previous.root, previous.path),
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Row(
        children: [
          BayaSurface(
            radius: 24,
            padding: EdgeInsets.zero,
            child: SizedBox.square(
              dimension: 46,
              child: IconButton(
                tooltip: state is SessionFilesFile
                    ? context.l10n.backToDirectory
                    : context.l10n.backToSession,
                onPressed: onBack,
                icon: Icon(
                  LucideIcons.chevronLeft,
                  size: 21,
                  color: context.colors.text,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.35,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.monoSmall.copyWith(
                    color: context.colors.muted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (onUpload != null)
            IconButton(
              key: const ValueKey('session-files-upload'),
              tooltip: context.l10n.uploadFromPhone,
              onPressed: state is SessionFilesLoading ? null : onUpload,
              icon: const Icon(LucideIcons.upload, size: 19),
            ),
          if (onSave != null)
            IconButton(
              key: const ValueKey('session-files-save'),
              tooltip: context.l10n.saveToPhone,
              onPressed: onSave,
              icon: const Icon(LucideIcons.download, size: 19),
            ),
          if (onToggleHidden != null)
            IconButton(
              tooltip: showHidden
                  ? context.l10n.hideHiddenFiles
                  : context.l10n.showHiddenFiles,
              onPressed: onToggleHidden,
              icon: Icon(
                showHidden ? LucideIcons.eyeOff : LucideIcons.eye,
                size: 19,
              ),
            ),
          IconButton(
            tooltip: context.l10n.refresh,
            onPressed: state is SessionFilesLoading ? null : onRefresh,
            icon: const Icon(LucideIcons.refreshCw, size: 19),
          ),
        ],
      ),
    );
  }
}

class _DirectoryView extends StatelessWidget {
  const _DirectoryView({
    required this.directory,
    required this.onOpenDirectory,
    required this.onOpenFile,
    this.busy = false,
  });

  final SessionDirectoryListing directory;
  final ValueChanged<String> onOpenDirectory;
  final ValueChanged<SessionFileEntry> onOpenFile;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
      children: [
        _Breadcrumbs(
          root: directory.root,
          path: directory.path,
          onOpen: busy ? null : onOpenDirectory,
        ),
        const SizedBox(height: 10),
        if (directory.parent != null)
          _FileRow(
            key: const ValueKey('session-files-parent'),
            icon: LucideIcons.cornerLeftUp,
            title: context.l10n.parentDirectory,
            subtitle: directory.parent!,
            onTap: busy ? null : () => onOpenDirectory(directory.parent!),
          ),
        if (directory.entries.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 52),
            child: Column(
              children: [
                Icon(
                  LucideIcons.folderSearch,
                  size: 30,
                  color: context.colors.muted,
                ),
                const SizedBox(height: 12),
                Text(
                  context.l10n.noFilesHere,
                  style: context.typo.sansBody.copyWith(
                    color: context.colors.muted,
                  ),
                ),
              ],
            ),
          )
        else
          BayaSurface(
            role: BayaSurfaceRole.content,
            radius: 18,
            elevated: false,
            child: Column(
              children: [
                for (var i = 0; i < directory.entries.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 44,
                      color: context.colors.border.withValues(alpha: .7),
                    ),
                  _entryRow(context, directory.entries[i]),
                ],
              ],
            ),
          ),
        if (directory.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              context.l10n.first500Entries,
              style: context.typo.sansBody.copyWith(
                color: context.colors.muted,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

extension on _DirectoryView {
  Widget _entryRow(BuildContext context, SessionFileEntry entry) {
    final folder = entry.kind == SessionFileKind.directory;
    return _FileRow(
      key: ValueKey('session-file-${entry.path}'),
      icon: folder ? LucideIcons.folder : _fileIcon(entry.name),
      iconColor: folder ? context.colors.highlight : context.colors.muted2,
      title: entry.name,
      subtitle: folder ? context.l10n.directory : _entryMetadata(entry),
      trailing: folder ? LucideIcons.chevronRight : null,
      onTap: busy
          ? null
          : () => folder ? onOpenDirectory(entry.path) : onOpenFile(entry),
    );
  }
}

/// Where the listing is, from the session's folder down; each part opens.
class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({
    required this.root,
    required this.path,
    required this.onOpen,
  });

  final String root;
  final String path;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final separator = root.contains('\\') ? '\\' : '/';
    final relative = _relativePath(root, path);
    final parts = relative == _baseName(root)
        ? <String>[]
        : relative.split('/').where((part) => part.isNotEmpty).toList();
    final crumbs = <(String, String)>[
      (_baseName(root), root),
      for (var i = 0; i < parts.length; i++)
        (
          parts[i],
          [
            root.replaceAll(RegExp(r'[\\/]+$'), ''),
            ...parts.take(i + 1),
          ].join(separator),
        ),
    ];
    return SingleChildScrollView(
      key: const ValueKey('session-files-breadcrumbs'),
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        children: [
          for (var i = 0; i < crumbs.length; i++) ...[
            if (i > 0)
              Icon(LucideIcons.chevronRight, size: 14, color: colors.muted),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: i == crumbs.length - 1
                    ? colors.text
                    : colors.muted2,
              ),
              onPressed: i == crumbs.length - 1 || onOpen == null
                  ? null
                  : () => onOpen!(crumbs[i].$2),
              child: Text(
                crumbs[i].$1,
                style: context.typo.sansBody.copyWith(
                  fontSize: 14,
                  fontWeight: i == crumbs.length - 1
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: i == crumbs.length - 1 ? colors.text : colors.muted2,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? iconColor;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 19, color: iconColor ?? context.colors.muted2),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.sansBody.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.monoSmall.copyWith(
                        fontSize: 10.5,
                        color: context.colors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null)
                Icon(trailing, size: 17, color: context.colors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileView extends StatefulWidget {
  const _FileView({
    required this.file,
    required this.transfer,
    required this.onOpenElsewhere,
    required this.onOpenPath,
  });
  final SessionFileContent file;
  final FileTransfer? transfer;
  final VoidCallback onOpenElsewhere;
  final void Function(String path, String name) onOpenPath;

  @override
  State<_FileView> createState() => _FileViewState();
}

class _FileViewState extends State<_FileView> {
  late bool _rendered = _isMarkdown || _delimiter != null;

  bool get _isMarkdown =>
      CodeHighlighter.languageForPath(widget.file.name) == 'markdown';

  /// CSV and TSV show as a table, their source a tap away.
  String? get _delimiter => delimiterFor(widget.file.name);

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final content = file.content;
    final text = !file.binary && content != null && content.isNotEmpty
        ? content
        : null;
    final kind = previewKindFor(file.name);
    final transfer = widget.transfer;
    if (kind != null && transfer != null) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: _FileHeader(file: file),
          ),
          Expanded(
            child: FilePreview(
              key: ValueKey(file.path),
              path: file.path,
              name: file.name,
              kind: kind,
              transfer: transfer,
              onOpenPath: widget.onOpenPath,
            ),
          ),
        ],
      );
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
          sliver: SliverToBoxAdapter(child: _FileHeader(file: file)),
        ),
        if (file.binary)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _FileNotice(
                    icon: LucideIcons.fileArchive,
                    title: context.l10n.binaryFile,
                    message: context.l10n.binaryFileHint,
                  ),
                  const SizedBox(height: 12),
                  BayaButton(
                    buttonKey: const Key('session-file-open-elsewhere'),
                    onPressed: widget.onOpenElsewhere,
                    icon: const Icon(LucideIcons.externalLink, size: 18),
                    label: Text(context.l10n.openWithApp),
                    prominent: false,
                  ),
                ],
              ),
            ),
          )
        else if (text == null)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            sliver: SliverToBoxAdapter(
              child: _FileNotice(
                icon: LucideIcons.file,
                title: context.l10n.emptyFile,
                message: context.l10n.noTextContent,
              ),
            ),
          )
        else ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  if (_isMarkdown || _delimiter != null)
                    SegmentedButton<bool>(
                      key: const ValueKey('session-file-view'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(
                            _delimiter != null
                                ? context.l10n.table
                                : context.l10n.preview,
                          ),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text(context.l10n.source),
                        ),
                      ],
                      selected: {_rendered},
                      onSelectionChanged: (value) =>
                          setState(() => _rendered = value.first),
                    ),
                  const Spacer(),
                  BayaCopyButton(key: const Key('code-copy'), text: text),
                ],
              ),
            ),
          ),
          if (_delimiter != null && _rendered)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              sliver: SliverToBoxAdapter(
                child: DelimitedTable(
                  key: const ValueKey('session-file-table'),
                  text: text,
                  delimiter: _delimiter!,
                ),
              ),
            )
          else if (_isMarkdown && _rendered)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              sliver: SliverToBoxAdapter(
                child: AgentMarkdown(text, selectable: true),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              sliver: _CodeLines(
                key: const ValueKey('session-file-content'),
                code: text,
                language: CodeHighlighter.languageForPath(file.name),
              ),
            ),
        ],
        if (file.truncated && !file.binary)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                context.l10n.first256Kb,
                style: context.typo.sansBody.copyWith(
                  color: context.colors.warning,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
      ],
    );
  }
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({required this.file});
  final SessionFileContent file;

  @override
  Widget build(BuildContext context) {
    return BayaSurface(
      role: BayaSurfaceRole.content,
      radius: 18,
      elevated: false,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _fileIcon(file.name),
                size: 19,
                color: context.colors.highlight,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  file.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.monoSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _MetadataChip(label: formatBytes(file.size)),
              if (file.modifiedAt case final modified?)
                _MetadataChip(label: _formatDate(modified)),
              if (file.truncated)
                _MetadataChip(label: context.l10n.previewTruncated),
            ],
          ),
        ],
      ),
    );
  }
}

/// A file's lines, numbered and wrapped, built only as they scroll into view
/// so a large file opens at once; colour arrives from a background isolate.
class _CodeLines extends StatefulWidget {
  const _CodeLines({super.key, required this.code, required this.language});

  final String code;
  final String? language;

  @override
  State<_CodeLines> createState() => _CodeLinesState();
}

class _CodeLinesState extends State<_CodeLines> {
  late List<List<Token>> _lines = _plain();

  List<List<Token>> _plain() => [
    for (final line in widget.code.split('\n')) [(line, null)],
  ];

  @override
  void initState() {
    super.initState();
    final language = CodeHighlighter.resolve(widget.language);
    if (language == null) return;
    final cached = CodeHighlighter.cachedTokens(widget.code, language);
    if (cached != null) {
      _lines = tokenLines(cached);
      return;
    }
    CodeHighlighter.tokensLater(widget.code, language).then((tokens) {
      if (mounted) setState(() => _lines = tokenLines(tokens));
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = codeTextStyle(context, size: 12).copyWith(color: colors.text);
    final numberStyle = style.copyWith(
      color: colors.muted.withValues(alpha: .7),
    );
    final brightness = Theme.of(context).brightness;
    final gutter = '${_lines.length}'.length * 7.5 + 8;
    return DecoratedSliver(
      decoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: BorderRadius.circular(12),
      ),
      sliver: SliverPadding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        sliver: SliverList.builder(
          itemCount: _lines.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: gutter,
                  child: Text(
                    '${index + 1}',
                    textAlign: TextAlign.right,
                    style: numberStyle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text.rich(
                    CodeHighlighter.spans(_lines[index], style, brightness),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: context.colors.modelBadgeBg,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: context.colors.modelBadgeBorder),
      ),
      child: Text(
        label,
        style: context.typo.sansBody.copyWith(
          color: context.colors.muted2,
          fontSize: 10.5,
        ),
      ),
    );
  }
}

class _FileNotice extends StatelessWidget {
  const _FileNotice({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return BayaSurface(
      role: BayaSurfaceRole.content,
      radius: 18,
      elevated: false,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: context.colors.muted2),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.typo.sansBody.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: context.typo.sansBody.copyWith(
                    color: context.colors.muted,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.folderX, size: 34, color: context.colors.error),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.typo.sansBody.copyWith(
                color: context.colors.muted2,
                fontSize: 13.5,
              ),
            ),
            const SizedBox(height: 16),
            BayaButton(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.refreshCw, size: 17),
              label: Text(context.l10n.tryAgain),
              prominent: false,
            ),
          ],
        ),
      ),
    );
  }
}

String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

String _relativePath(String root, String path) {
  final normalizedRoot = root
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '');
  final normalizedPath = path.replaceAll('\\', '/');
  if (normalizedPath == normalizedRoot) return _baseName(root);
  if (normalizedPath.startsWith('$normalizedRoot/')) {
    return normalizedPath.substring(normalizedRoot.length + 1);
  }
  return normalizedPath;
}

IconData _fileIcon(String name) {
  final lower = name.toLowerCase();
  if (RegExp(r'\.(png|jpe?g|gif|webp|svg|ico)$').hasMatch(lower)) {
    return LucideIcons.image;
  }
  if (RegExp(r'\.(md|mdx|txt|rst)$').hasMatch(lower)) {
    return LucideIcons.fileText;
  }
  if (RegExp(r'\.(dart|js|ts|tsx|jsx|py|go|rs|java|kt|swift|sh|ps1)$')
      .hasMatch(lower)) {
    return LucideIcons.code;
  }
  return LucideIcons.file;
}

String _entryMetadata(SessionFileEntry entry) {
  final pieces = <String>[];
  if (entry.size case final size?) pieces.add(formatBytes(size));
  if (entry.modifiedAt case final modified?) pieces.add(_formatDate(modified));
  return pieces.isEmpty ? appL10n.file : pieces.join('  ·  ');
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
