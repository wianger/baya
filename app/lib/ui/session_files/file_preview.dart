import 'dart:async';
import 'dart:io';

import 'package:app/data/preview/pdf_document.dart';
import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/transfer/transfer_flow.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';

/// What the phone can show of a file itself, beyond text.
enum PreviewKind { image, pdf }

const _images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

PreviewKind? previewKindFor(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  if (_images.contains(ext)) return PreviewKind.image;
  if (ext == 'pdf') return PreviewKind.pdf;
  return null;
}

/// Fetches the whole file into the phone's cache, then shows it: an image
/// to pinch and pan, or a PDF to scroll. The copy goes when the view does.
class FilePreview extends StatefulWidget {
  const FilePreview({
    super.key,
    required this.path,
    required this.name,
    required this.kind,
    required this.transfer,
    @visibleForTesting this.folder,
  });

  final String path;
  final String name;
  final PreviewKind kind;
  final FileTransfer transfer;

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

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    setState(() {
      _error = null;
      _done = _total = 0;
    });
    try {
      final base = await (widget.folder ?? getTemporaryDirectory)();
      final dir = Directory(
        '${base.path}/previews/${DateTime.now().microsecondsSinceEpoch}',
      );
      await dir.create(recursive: true);
      final file = File('${dir.path}/${widget.name}');
      final sink = file.openWrite();
      try {
        await widget.transfer.download(
          widget.path,
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
      setState(() => _error = error);
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
        PreviewKind.pdf => _PdfPages(
          key: const ValueKey('file-preview-pdf'),
          path: file.path,
        ),
      };
    }
    if (_error != null) {
      return _Message(
        icon: LucideIcons.fileWarning,
        text: _error is TransferTooLarge
            ? context.l10n.fileTooLarge(widget.name)
            : context.l10n.previewFailed,
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
              _total > 0
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
