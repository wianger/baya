import 'dart:ui' show Tangent;

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

const kAppName = 'Baya';

/// The woven nest a baya weaver hangs from a branch: a round chamber, an
/// entrance below, straw strands wound across it. Geometry matches
/// branding/generate.py (108-unit grid).
///
/// [tile] draws it on its graphite tile, as on the launcher; without one the
/// mark sits on the page, its gaps cut through to whatever is behind.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 28, this.tile = false});
  final double size;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      label: kAppName,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: AppMarkPainter(
          tile: tile,
          branch: tile ? AppBrandColors.branch : colors.muted2,
        ),
      ),
    );
  }
}

/// "Baya" set in Geist, beside the mark.
class AppWordmark extends StatelessWidget {
  const AppWordmark({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppMark(size: size * 1.35),
        SizedBox(width: size * .3),
        Text(
          kAppName,
          style: brandDisplayTextStyle(
            fontSize: size,
            color: context.colors.text,
          ),
        ),
      ],
    );
  }
}

class AppMarkPainter extends CustomPainter {
  const AppMarkPainter({required this.tile, required this.branch});

  final bool tile;
  final Color branch;

  static Path get nest => Path()
    ..moveTo(54, 29)
    ..cubicTo(67.5, 29, 77, 40, 77, 53)
    ..cubicTo(77, 66, 68, 75, 61.5, 80.5)
    ..lineTo(61.5, 84.5)
    ..arcToPoint(const Offset(46.5, 84.5), radius: const Radius.circular(7.5))
    ..lineTo(46.5, 80.5)
    ..cubicTo(40, 75, 31, 66, 31, 53)
    ..cubicTo(31, 40, 40.5, 29, 54, 29)
    ..close();

  static Path get strands => Path()
    ..moveTo(29, 45)
    ..cubicTo(42, 52.5, 54, 63, 61.5, 77.5)
    ..moveTo(33, 32)
    ..cubicTo(51, 40, 67, 54, 77, 72);

  static final _hole = Rect.fromCenter(
    center: const Offset(54, 85),
    width: 7.2,
    height: 6.4,
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 108, size.height / 108);
    if (tile) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(0, 0, 108, 108),
          const Radius.circular(24),
        ),
        Paint()..color = AppBrandColors.graphite,
      );
    }
    canvas.drawPath(
      Path()
        ..moveTo(30, 26.5)
        ..cubicTo(44, 23.6, 64, 23.6, 78, 26.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = branch,
    );
    canvas.drawLine(
      const Offset(54, 25),
      const Offset(54, 31),
      Paint()
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = AppBrandColors.strawLight,
    );
    // The strands and the entrance are cut out, so the mark works on any
    // background, the tile included.
    final strandsOutline = _strokeOutline(strands, 3.4);
    final body = Path.combine(
      PathOperation.difference,
      Path.combine(PathOperation.difference, nest, strandsOutline),
      Path()..addOval(_hole),
    );
    canvas.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment(-0.33, -1),
          end: Alignment(0.3, 1),
          colors: [AppBrandColors.strawLight, AppBrandColors.strawDeep],
        ).createShader(const Rect.fromLTRB(31, 29, 77, 92)),
    );
    canvas.restore();
  }

  /// The area a stroke of [width] along [path] covers, sampled as quads.
  static Path _strokeOutline(Path path, double width) {
    final outline = Path();
    for (final metric in path.computeMetrics()) {
      final steps = (metric.length / 1.5).ceil();
      for (var i = 0; i < steps; i++) {
        final a = metric.getTangentForOffset(metric.length * i / steps)!;
        final b = metric.getTangentForOffset(metric.length * (i + 1) / steps)!;
        Offset normal(Tangent t) =>
            Offset(-t.vector.dy, t.vector.dx) * (width / 2);
        outline.addPolygon([
          a.position + normal(a),
          b.position + normal(b),
          b.position - normal(b),
          a.position - normal(a),
        ], true);
      }
    }
    return outline;
  }

  @override
  bool shouldRepaint(AppMarkPainter old) =>
      old.tile != tile || old.branch != branch;
}
