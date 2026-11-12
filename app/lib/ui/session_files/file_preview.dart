import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/preview/pdf_document.dart';
import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/code/code_view.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/transfer/transfer_flow.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// What the phone can show of a file itself, beyond text.
enum PreviewKind { image, svg, pdf, video, audio, notebook, archive, office }

final _kinds = {
  for (final ext in [
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
  ])
    ext: PreviewKind.image,
  'svg': PreviewKind.svg,
  'pdf': PreviewKind.pdf,
  for (final ext in ['mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp'])
    ext: PreviewKind.video,
  for (final ext in ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'flac', 'opus'])
    ext: PreviewKind.audio,
  'ipynb': PreviewKind.notebook,
  for (final ext in ['zip', 'jar', 'apk', 'aar', 'whl', 'epub', 'tar', 'tgz'])
    ext: PreviewKind.archive,
  for (final ext in [
    'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'rtf', //
  ])
    ext: PreviewKind.office,
};

PreviewKind? previewKindFor(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.tar.gz')) return PreviewKind.archive;
  final dot = lower.lastIndexOf('.');
  return dot < 0 ? null : _kinds[lower.substring(dot + 1)];
}

/// Comma- or tab-separated text, shown as a table.
String? delimiterFor(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.csv')) return ',';
  if (lower.endsWith('.tsv') || lower.endsWith('.tab')) return '\t';
  return null;
}

/// Shows a file the phone can render: fetched whole into the cache (gone
/// when the view is), an office document turned into PDF on the computer
/// first, or an archive's entries listed by the computer.
class FilePreview extends StatefulWidget {
  const FilePreview({
    super.key,
    required this.path,
    required this.name,
    required this.kind,
    required this.transfer,
    this.onOpenPath,
    @visibleForTesting this.folder,
  });

  final String path;
  final String name;
  final PreviewKind kind;
  final FileTransfer transfer;

  /// Opens a file the computer just made (an archive's entry).
  final void Function(String path, String name)? onOpenPath;

  /// Where the copy goes; the cache by default.
  final Future<Directory> Function()? folder;

  @override
  State<FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends State<FilePreview> {
  final _control = TransferControl();
  File? _file;
  Object? _error;
  int _done = 0;
  int _total = 0;
  bool _converting = false;

  @override
  void initState() {
    super.initState();
    if (widget.kind != PreviewKind.archive) unawaited(_fetch());
  }

  Future<void> _fetch() async {
    setState(() {
      _error = null;
      _done = _total = 0;
    });
    try {
      var source = widget.path;
      var name = widget.name;
      if (widget.kind == PreviewKind.office) {
        setState(() => _converting = true);
        final pdf = await widget.transfer.call('_baya/convert_pdf', {
          'path': source,
        });
        if (!mounted) return;
        setState(() => _converting = false);
        source = pdf['path'] as String;
        name = pdf['name'] as String;
      }
      final base = await (widget.folder ?? getTemporaryDirectory)();
      final dir = Directory(
        '${base.path}/previews/${DateTime.now().microsecondsSinceEpoch}',
      );
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name');
      final sink = file.openWrite();
      try {
        await widget.transfer.download(
          source,
          sink,
          control: _control,
          onProgress: (done, total) {
            if (!mounted) return;
            setState(() {
              _done = done;
              _total = total;
            });
          },
        );
      } finally {
        await sink.close();
      }
      if (!mounted) {
        unawaited(_drop(file));
        return;
      }
      setState(() => _file = file);
    } catch (error) {
      if (error is TransferCancelled || !mounted) return;
      setState(() {
        _converting = false;
        _error = error;
      });
    }
  }

  static Future<void> _drop(File file) async {
    try {
      await file.parent.delete(recursive: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _control.cancel();
    final file = _file;
    if (file != null) unawaited(_drop(file));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (widget.kind == PreviewKind.archive) {
      return _ArchiveView(
        path: widget.path,
        call: widget.transfer.call,
        onOpenPath: widget.onOpenPath,
      );
    }
    final file = _file;
    if (file != null) {
      return switch (widget.kind) {
        PreviewKind.image => ClipRect(
          child: InteractiveViewer(
            key: const ValueKey('file-preview-image'),
            maxScale: 8,
            child: Center(
              child: Image.file(
                file,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => _Message(
                  icon: LucideIcons.imageOff,
                  text: context.l10n.previewFailed,
                ),
              ),
            ),
          ),
        ),
        PreviewKind.pdf || PreviewKind.office => _PdfPages(
          key: const ValueKey('file-preview-pdf'),
          path: file.path,
        ),
        PreviewKind.svg => ClipRect(
          child: InteractiveViewer(
            key: const ValueKey('file-preview-svg'),
            maxScale: 8,
            child: Center(
              child: SvgPicture.file(
                file,
                errorBuilder: (_, _, _) => _Message(
                  icon: LucideIcons.imageOff,
                  text: context.l10n.previewFailed,
                ),
              ),
            ),
          ),
        ),
        PreviewKind.video || PreviewKind.audio => _Player(
          key: const ValueKey('file-preview-player'),
          file: file,
          audio: widget.kind == PreviewKind.audio,
        ),
        PreviewKind.notebook => _Notebook(
          key: const ValueKey('file-preview-notebook'),
          file: file,
        ),
        PreviewKind.archive => const SizedBox.shrink(),
      };
    }
    final error = _error;
    if (error != null) {
      return _Message(
        icon: LucideIcons.fileWarning,
        text: switch (error) {
          TransferTooLarge() => context.l10n.fileTooLarge(widget.name),
          RpcError(reason: 'no_office') => context.l10n.installLibreOffice,
          RpcError(:final message) => message,
          _ => context.l10n.previewFailed,
        },
        action: TextButton(
          onPressed: _fetch,
          child: Text(context.l10n.tryAgain),
        ),
      );
    }
    return Center(
      key: const ValueKey('file-preview-loading'),
      child: SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 5,
                value: _total > 0 ? _done / _total : null,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _converting
                  ? context.l10n.convertingToPdf
                  : _total > 0
                  ? '${formatBytes(_done)} / ${formatBytes(_total)}'
                  : context.l10n.loadingPreview,
              style: context.typo.monoSmall.copyWith(color: colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A PDF's pages one under another, each rendered as it scrolls into view
/// at the screen's resolution; pinch to zoom.
class _PdfPages extends StatefulWidget {
  const _PdfPages({super.key, required this.path});

  final String path;

  @override
  State<_PdfPages> createState() => _PdfPagesState();
}

class _PdfPagesState extends State<_PdfPages> {
  late final Future<PdfDocument> _document = PdfDocument.open(widget.path);
  final _pages = <int, Future<Uint8List>>{};

  @override
  void dispose() {
    unawaited(_document.then((document) => document.close(), onError: (_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PdfDocument>(
      future: _document,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            icon: LucideIcons.fileWarning,
            text: context.l10n.previewFailed,
          );
        }
        final document = snapshot.data;
        if (document == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth - 24;
            final pixels =
                (width * MediaQuery.devicePixelRatioOf(context) * 1.5).round();
            return InteractiveViewer(
              maxScale: 5,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                itemCount: document.pageSizes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final size = document.pageSizes[index];
                  // Pages far from the one in view give their memory back.
                  _pages.removeWhere((page, _) => (page - index).abs() > 8);
                  final image = _pages[index] ??= document.render(
                    index,
                    pixels,
                  );
                  return AspectRatio(
                    aspectRatio: size.width / size.height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .18),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      child: FutureBuilder<Uint8List>(
                        future: image,
                        builder: (context, page) => page.hasData
                            ? Image.memory(
                                page.data!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              )
                            : const SizedBox.expand(),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

/// Rows of comma- or tab-separated [text]; quoted fields may hold the
/// delimiter, line breaks and doubled quotes.
List<List<String>> parseDelimited(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"' && field.isEmpty) {
      quoted = true;
    } else if (c == delimiter) {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

/// A CSV or TSV as a table: the first row as its header, scrolling
/// sideways when it is wider than the screen.
class DelimitedTable extends StatelessWidget {
  const DelimitedTable({
    super.key,
    required this.text,
    required this.delimiter,
  });

  final String text;
  final String delimiter;

  static const _maxRows = 2000;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final all = parseDelimited(text, delimiter);
    final rows = all.take(_maxRows).toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.fold<int>(
      0,
      (n, row) => row.length > n ? row.length : n,
    );
    Widget cell(String value, {bool head = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Text(
          value,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: context.typo.sansBody.copyWith(
            fontSize: 13,
            fontWeight: head ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: colors.border, width: .7),
            children: [
              for (var r = 0; r < rows.length; r++)
                TableRow(
                  decoration: r == 0
                      ? BoxDecoration(color: colors.selection)
                      : null,
                  children: [
                    for (var c = 0; c < columns; c++)
                      cell(c < rows[r].length ? rows[r][c] : '', head: r == 0),
                  ],
                ),
            ],
          ),
        ),
        if (all.length > _maxRows)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              context.l10n.firstRows(_maxRows),
              style: context.typo.sansBody.copyWith(
                color: colors.muted,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

/// An archive's entries as the computer reads them; a file entry is taken
/// out into the session's `.baya/extracted` and opens like any file.
class _ArchiveView extends StatefulWidget {
  const _ArchiveView({
    required this.path,
    required this.call,
    required this.onOpenPath,
  });

  final String path;
  final SessionCall call;
  final void Function(String path, String name)? onOpenPath;

  @override
  State<_ArchiveView> createState() => _ArchiveViewState();
}

class _ArchiveViewState extends State<_ArchiveView> {
  late Future<Json> _listing = _list();
  String? _opening;

  Future<Json> _list() =>
      widget.call('_baya/archive_list', {'path': widget.path});

  Future<void> _open(String entry) async {
    setState(() => _opening = entry);
    try {
      final out = await widget.call('_baya/archive_extract', {
        'path': widget.path,
        'entry': entry,
      });
      if (!mounted) return;
      widget.onOpenPath?.call(out['path'] as String, out['name'] as String);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(error is RpcError ? error.message : '$error')),
      );
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<Json>(
      future: _listing,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final error = snapshot.error;
          return _Message(
            icon: LucideIcons.fileWarning,
            text: error is RpcError
                ? error.message
                : context.l10n.previewFailed,
            action: TextButton(
              onPressed: () => setState(() => _listing = _list()),
              child: Text(context.l10n.tryAgain),
            ),
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final entries = (data['entries'] as List)
            .cast<Map<String, dynamic>>()
            .where((e) => e['directory'] != true)
            .toList();
        return ListView.builder(
          key: const ValueKey('file-preview-archive'),
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
          itemCount: entries.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  context.l10n.archiveEntries(entries.length),
                  style: context.typo.sansBody.copyWith(
                    color: colors.muted,
                    fontSize: 12.5,
                  ),
                ),
              );
            }
            final entry = entries[index - 1];
            final name = entry['name'] as String;
            final slash = name.lastIndexOf('/');
            return ListTile(
              key: ValueKey('archive-entry-$name'),
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: _opening == name
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(LucideIcons.file, size: 18, color: colors.muted2),
              title: Text(
                slash < 0 ? name : name.substring(slash + 1),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (slash > 0) name.substring(0, slash),
                  formatBytes((entry['size'] as num).toInt()),
                ].join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typo.monoSmall.copyWith(color: colors.muted),
              ),
              onTap: _opening != null || widget.onOpenPath == null
                  ? null
                  : () => _open(name),
            );
          },
        );
      },
    );
  }
}

/// Plays a video (or the sound of an audio file) with play/pause and a bar
/// to seek along.
class _Player extends StatefulWidget {
  const _Player({super.key, required this.file, required this.audio});

  final File file;
  final bool audio;

  @override
  State<_Player> createState() => _PlayerState();
}

class _PlayerState extends State<_Player> {
  late final VideoPlayerController _controller = VideoPlayerController.file(
    widget.file,
  );
  late final Future<void> _ready = _controller.initialize();

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  static String _clock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final hours = d.inHours;
    final rest = '${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
    return hours > 0 ? '$hours:$rest' : rest;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            icon: LucideIcons.fileWarning,
            text: context.l10n.previewFailed,
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return Column(
          children: [
            Expanded(
              child: Center(
                child: widget.audio || _controller.value.size.isEmpty
                    ? Icon(LucideIcons.music, size: 72, color: colors.muted)
                    : AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
              ),
            ),
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: _controller,
              builder: (context, value, _) => Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 24),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('player-toggle'),
                      onPressed: () => value.isPlaying
                          ? _controller.pause()
                          : _controller.play(),
                      icon: Icon(
                        value.isPlaying ? LucideIcons.pause : LucideIcons.play,
                      ),
                    ),
                    Expanded(
                      child: VideoProgressIndicator(
                        _controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        colors: VideoProgressColors(
                          playedColor: colors.accent,
                          bufferedColor: colors.border,
                          backgroundColor: colors.selection,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${_clock(value.position)} / ${_clock(value.duration)}',
                      style: context.typo.monoSmall.copyWith(
                        color: colors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A Jupyter notebook: markdown cells rendered, code cells highlighted,
/// with their text and image outputs.
class _Notebook extends StatefulWidget {
  const _Notebook({super.key, required this.file});

  final File file;

  @override
  State<_Notebook> createState() => _NotebookState();
}

class _NotebookState extends State<_Notebook> {
  // Notebooks are small; reading it at once keeps the view simple.
  late final Future<List<Map<String, dynamic>>> _cells = Future.sync(() {
    final json = jsonDecode(widget.file.readAsStringSync()) as Map;
    return (json['cells'] as List).cast<Map<String, dynamic>>();
  });

  static String _text(Object? source) => switch (source) {
    final List<Object?> lines => lines.join(),
    final String text => text,
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder(
      future: _cells,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            icon: LucideIcons.fileWarning,
            text: context.l10n.previewFailed,
          );
        }
        final cells = snapshot.data;
        if (cells == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
          itemCount: cells.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final cell = cells[index];
            final source = _text(cell['source']);
            if (cell['cell_type'] == 'markdown') {
              return AgentMarkdown(source, selectable: true);
            }
            if (cell['cell_type'] != 'code') {
              return Text(source, style: context.typo.monoSmall);
            }
            final outputs = (cell['outputs'] as List? ?? const [])
                .cast<Map<String, dynamic>>();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CodeBlock(
                  code: source,
                  language: 'python',
                  title: cell['execution_count'] == null
                      ? null
                      : 'In [${cell['execution_count']}]',
                ),
                for (final output in outputs) ...[
                  const SizedBox(height: 6),
                  _output(context, output, colors),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _output(
    BuildContext context,
    Map<String, dynamic> output,
    AppColors colors,
  ) {
    final data = output['data'] as Map<String, dynamic>?;
    final png = data?['image/png'];
    if (png != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Image.memory(
          base64Decode(_text(png).replaceAll('\n', '')),
          fit: BoxFit.contain,
        ),
      );
    }
    final text = output['output_type'] == 'error'
        ? '${output['ename']}: ${output['evalue']}'
        : _text(output['text'] ?? data?['text/plain']);
    return SelectableText(
      text,
      style: context.typo.monoSmall.copyWith(
        color: output['output_type'] == 'error' ? colors.error : colors.muted2,
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 30, color: context.colors.muted),
        const SizedBox(height: 10),
        Text(
          text,
          style: context.typo.sansBody.copyWith(color: context.colors.muted),
        ),
        ?action,
      ],
    ),
  );
}
