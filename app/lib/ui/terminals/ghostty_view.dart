/// The trial terminal engine: Ghostty's libghostty-vt keeps the screen
/// (parsing, scrollback, modes), and this view paints it.
///
/// Painting follows the research notes: rows the engine reports unchanged
/// are replayed from a recorded picture, so an idle or slowly changing
/// screen costs almost nothing; each glyph is laid out once per style and
/// cached; and every glyph is placed in its cells and squeezed to fit them,
/// so Nerd Font icons and wide characters line up as on the computer.
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:libghostty/libghostty.dart' as vt;

/// How fast the engine took the bytes and how long a frame took to paint,
/// for comparing engines on the phone.
class TerminalStats extends ChangeNotifier {
  int _bytes = 0;
  Duration _writing = Duration.zero;
  final _frames = ListQueue<int>();

  /// Megabytes the parser took per second of its own time.
  double get mbPerSecond => _writing == Duration.zero
      ? 0
      : _bytes / 1e6 / (_writing.inMicroseconds / 1e6);

  /// The slowest of the last 120 frames' paint, in milliseconds (p95).
  double get paintP95 {
    if (_frames.isEmpty) return 0;
    final sorted = _frames.toList()..sort();
    return sorted[(sorted.length * .95).floor().clamp(0, sorted.length - 1)] /
        1000;
  }

  void wrote(int bytes, Duration took) {
    _bytes += bytes;
    _writing += took;
    notifyListeners();
  }

  void painted(Duration took) {
    _frames.addLast(took.inMicroseconds);
    while (_frames.length > 120) {
      _frames.removeFirst();
    }
  }

  @override
  String toString() =>
      '${mbPerSecond.toStringAsFixed(1)} MB/s · '
      'p95 ${paintP95.toStringAsFixed(1)} ms';
}

/// The engine, fed bytes from the computer; answers it writes (cursor
/// reports, device attributes) go to [onOutput].
class GhosttyController extends ChangeNotifier {
  GhosttyController({required this.onOutput, int scrollback = 10000}) {
    terminal
      ..scrollbackMaxLines = scrollback
      ..onWritePty = (data) => onOutput(String.fromCharCodes(data));
  }

  final void Function(String) onOutput;
  final vt.Terminal terminal = vt.Terminal(cols: 80, rows: 24);
  final stats = TerminalStats();
  bool _scheduled = false;

  int get cols => _cols;
  int get rows => _rows;
  int _cols = 80;
  int _rows = 24;

  void write(Uint8List bytes) {
    final watch = Stopwatch()..start();
    terminal.write(bytes);
    stats.wrote(bytes.length, watch.elapsed);
    _repaint();
  }

  void resize(int cols, int rows, double cellWidth, double cellHeight) {
    if (cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    terminal.resize(
      cols: cols,
      rows: rows,
      cellWidthPx: cellWidth.round(),
      cellHeightPx: cellHeight.round(),
    );
    _repaint();
  }

  /// Scrolls the view [lines] up (negative) or down.
  void scroll(int lines) {
    if (lines == 0) return;
    terminal.scrollViewport(lines);
    _repaint();
  }

  void toBottom() {
    terminal.scrollToBottom();
    _repaint();
  }

  /// A fresh screen: the computer paints it again after a reconnect.
  void reset() {
    terminal.reset();
    _repaint();
  }

  /// At most one paint per frame, however many writes came in.
  void _repaint() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _scheduled = false;
      notifyListeners();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    terminal.dispose();
    stats.dispose();
    super.dispose();
  }
}

class GhosttyView extends StatefulWidget {
  const GhosttyView({
    super.key,
    required this.controller,
    required this.fontSize,
    required this.onResize,
    this.fixed = false,
  });

  final GhosttyController controller;
  final double fontSize;

  /// Draws the controller's own grid at its natural size (a herdr pane's
  /// screen, sized on the computer) instead of fitting a grid to the view.
  final bool fixed;

  /// The grid this view holds, once laid out and whenever it changes.
  final void Function(int cols, int rows) onResize;

  @override
  State<GhosttyView> createState() => _GhosttyViewState();
}

class _GhosttyViewState extends State<GhosttyView> {
  final _state = vt.RenderState();
  final _rows = vt.RowIterator();
  final _cells = vt.CellIterator();
  double _drag = 0;

  @override
  void dispose() {
    _cells.dispose();
    _rows.dispose();
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final metrics = _CellMetrics.of(context, widget.fontSize);
    if (widget.fixed) {
      final c = widget.controller;
      return RepaintBoundary(
        child: CustomPaint(
          size: Size(12 + c.cols * metrics.width, c.rows * metrics.height),
          painter: _GhosttyPainter(
            controller: c,
            state: _state,
            rows: _rows,
            cells: _cells,
            metrics: metrics,
            foreground: colors.text,
            background: colors.bg,
            cursor: colors.text,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = math.max(
          10,
          ((constraints.maxWidth - 12) / metrics.width).floor(),
        );
        final rows = math.max(
          4,
          (constraints.maxHeight / metrics.height).floor(),
        );
        if (cols != widget.controller.cols || rows != widget.controller.rows) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            widget.controller.resize(cols, rows, metrics.width, metrics.height);
            widget.onResize(cols, rows);
          });
        }
        return GestureDetector(
          // Dragging scrolls the scrollback, a line at a time.
          onVerticalDragUpdate: (details) {
            _drag += details.delta.dy;
            final lines = (_drag / metrics.height).truncate();
            if (lines != 0) {
              _drag -= lines * metrics.height;
              widget.controller.scroll(-lines);
            }
          },
          onVerticalDragEnd: (_) => _drag = 0,
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _GhosttyPainter(
                controller: widget.controller,
                state: _state,
                rows: _rows,
                cells: _cells,
                metrics: metrics,
                foreground: colors.text,
                background: colors.bg,
                cursor: colors.text,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A cell's size, from the mono face at a font size.
class _CellMetrics {
  const _CellMetrics(this.width, this.height, this.style);

  factory _CellMetrics.of(BuildContext context, double fontSize) {
    final style = TextStyle(
      fontFamily: kMonoFamily,
      fontFamilyFallback: const [
        'Symbols Nerd Font Mono',
        'Noto Sans Mono CJK SC',
        'Noto Color Emoji',
      ],
      fontSize: fontSize,
      height: 1.2,
    );
    final probe = TextPainter(
      text: TextSpan(text: 'M', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final metrics = _CellMetrics(probe.width, probe.height, style);
    probe.dispose();
    return metrics;
  }

  final double width;
  final double height;
  final TextStyle style;
}

class _GhosttyPainter extends CustomPainter {
  _GhosttyPainter({
    required this.controller,
    required this.state,
    required this.rows,
    required this.cells,
    required this.metrics,
    required this.foreground,
    required this.background,
    required this.cursor,
  }) : super(repaint: controller);

  final GhosttyController controller;
  final vt.RenderState state;
  final vt.RowIterator rows;
  final vt.CellIterator cells;
  final _CellMetrics metrics;
  final Color foreground;
  final Color background;
  final Color cursor;

  /// Recorded rows by their place on screen, kept until the engine says
  /// that row changed.
  static final _rowPictures = Expando<(double, List<ui.Picture?>)>();

  /// Laid-out glyphs by text and style.
  static final _glyphs = <(String, int, bool, bool), ui.Paragraph>{};

  @override
  void paint(Canvas canvas, Size size) {
    final watch = Stopwatch()..start();
    final dirty = state.update(controller.terminal);
    // A new text size draws every row again.
    final kept = _rowPictures[controller];
    final stale = kept == null || kept.$1 != metrics.width;
    if (stale) {
      for (final picture in kept?.$2 ?? const <ui.Picture?>[]) {
        picture?.dispose();
      }
      _rowPictures[controller] = (metrics.width, <ui.Picture?>[]);
    }
    final pictures = _rowPictures[controller]!.$2;
    final full = stale || dirty == vt.DirtyState.full;
    rows.reset(state);
    var y = 0;
    while (rows.next()) {
      while (pictures.length <= y) {
        pictures.add(null);
      }
      if (full || rows.dirty || pictures[y] == null) {
        pictures[y]?.dispose();
        pictures[y] = _recordRow();
        rows.dirty = false;
      }
      canvas.drawPicture(pictures[y]!);
      canvas.translate(0, metrics.height);
      y++;
    }
    canvas.translate(0, -metrics.height * y);
    state.dirty = vt.DirtyState.clean;
    final at = state.cursor;
    if (at.visible && at.viewportHasValue) {
      canvas.drawRect(
        Rect.fromLTWH(
          6 + at.viewportX * metrics.width,
          at.viewportY * metrics.height,
          metrics.width,
          metrics.height,
        ),
        Paint()..color = cursor.withValues(alpha: .55),
      );
    }
    controller.stats.painted(watch.elapsed);
  }

  ui.Picture _recordRow() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    cells.reset(rows);
    while (cells.next()) {
      if (cells.wide == vt.CellWidth.spacerTail) continue;
      final span = cells.wide == vt.CellWidth.wide ? 2 : 1;
      final x = 6 + cells.col * metrics.width;
      final width = metrics.width * span;
      final style = cells.style;
      var fg = cells.foregroundArgb;
      var bg = cells.backgroundArgb;
      if (style.inverse) (fg, bg) = (bg ?? background.toARGB32(), fg);
      if (bg != null) {
        canvas.drawRect(
          Rect.fromLTWH(x, 0, width, metrics.height),
          Paint()..color = Color(bg),
        );
      }
      if (!cells.hasText || style.invisible) continue;
      final color = fg ?? foreground.toARGB32();
      final glyph = _glyph(cells.content, color, style.bold, style.italic);
      // Into its cells: squeezed when the font draws it wider.
      final natural = glyph.maxIntrinsicWidth;
      canvas.save();
      canvas.translate(x, 0);
      if (natural > width + .5) canvas.scale(width / natural, 1);
      canvas.drawParagraph(glyph, Offset.zero);
      canvas.restore();
    }
    return recorder.endRecording();
  }

  ui.Paragraph _glyph(String text, int color, bool bold, bool italic) {
    final key = (text, color, bold, italic);
    final hit = _glyphs.remove(key);
    if (hit != null) return _glyphs[key] = hit;
    final s = metrics.style;
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: s.fontFamily,
              fontSize: s.fontSize,
              height: s.height,
              maxLines: 1,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: Color(color),
              fontFamily: s.fontFamily,
              fontFamilyFallback: s.fontFamilyFallback,
              fontSize: s.fontSize,
              height: s.height,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              fontStyle: italic ? FontStyle.italic : FontStyle.normal,
            ),
          )
          ..addText(text);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    _glyphs[key] = paragraph;
    while (_glyphs.length > 4096) {
      _glyphs.remove(_glyphs.keys.first)?.dispose();
    }
    return paragraph;
  }

  @override
  bool shouldRepaint(_GhosttyPainter old) =>
      old.metrics.width != metrics.width ||
      old.foreground != foreground ||
      old.background != background;
}
