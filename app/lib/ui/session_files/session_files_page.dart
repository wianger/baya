import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/code/code_view.dart';
import 'package:app/ui/core/code/highlighter.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/session_files/states/session_files_state.dart';
import 'package:app/ui/session_files/viewmodels/session_files_viewmodel.dart';
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
      return _FileView(file: state.file);
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
  });

  final SessionFilesState state;
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
            ? context.l10n.sessionWorkspaceReadOnly
            : _relativePath(directory.root, directory.path),
      ),
      SessionFilesFile(:final file) => (
        file.name,
        context.l10n.readOnlyFilePreview,
      ),
      SessionFilesError(:final previous) => (
        previous == null ? context.l10n.sessionFiles : _baseName(previous.root),
        previous == null
            ? context.l10n.readOnlyBrowser
            : _relativePath(previous.root, previous.path),
      ),
      SessionFilesLoading(:final previous) => (
        previous == null ? context.l10n.sessionFiles : _baseName(previous.root),
        previous == null
            ? context.l10n.readOnlyBrowser
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

class _FileView extends StatelessWidget {
  const _FileView({required this.file});
  final SessionFileContent file;

  @override
  Widget build(BuildContext context) {
    final content = file.content;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
      children: [
        BayaSurface(
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
                  _MetadataChip(label: _formatBytes(file.size)),
                  if (file.modifiedAt case final modified?)
                    _MetadataChip(label: _formatDate(modified)),
                  if (file.truncated)
                    _MetadataChip(label: context.l10n.previewTruncated),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (file.binary)
          _FileNotice(
            icon: LucideIcons.fileArchive,
            title: context.l10n.binaryFile,
            message: context.l10n.binaryFileHint,
          )
        else if (content == null || content.isEmpty)
          _FileNotice(
            icon: LucideIcons.file,
            title: context.l10n.emptyFile,
            message: context.l10n.noTextContent,
          )
        else
          _FileContent(name: file.name, content: content),
        if (file.truncated && !file.binary)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              context.l10n.first256Kb,
              style: context.typo.sansBody.copyWith(
                color: context.colors.warning,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

/// A file's text: Markdown rendered (with its source a tap away), anything
/// else as highlighted code with line numbers.
class _FileContent extends StatefulWidget {
  const _FileContent({required this.name, required this.content});

  final String name;
  final String content;

  @override
  State<_FileContent> createState() => _FileContentState();
}

class _FileContentState extends State<_FileContent> {
  late bool _rendered = _isMarkdown;

  bool get _isMarkdown =>
      CodeHighlighter.languageForPath(widget.name) == 'markdown';

  @override
  Widget build(BuildContext context) {
    final code = CodeBlock(
      key: const ValueKey('session-file-content'),
      code: widget.content,
      language: CodeHighlighter.languageForPath(widget.name),
      title: CodeHighlighter.languageForPath(widget.name) ?? widget.name,
      lineNumbers: true,
    );
    if (!_isMarkdown) return code;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<bool>(
            key: const ValueKey('session-file-view'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: true, label: Text(context.l10n.preview)),
              ButtonSegment(value: false, label: Text(context.l10n.source)),
            ],
            selected: {_rendered},
            onSelectionChanged: (value) =>
                setState(() => _rendered = value.first),
          ),
        ),
        const SizedBox(height: 10),
        if (_rendered)
          AgentMarkdown(widget.content, selectable: true)
        else
          code,
      ],
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
  if (entry.size case final size?) pieces.add(_formatBytes(size));
  if (entry.modifiedAt case final modified?) pieces.add(_formatDate(modified));
  return pieces.isEmpty ? appL10n.file : pieces.join('  ·  ');
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
