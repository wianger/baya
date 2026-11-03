import 'package:app/ui/core/branding/mark_geometry.g.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

const kAppName = 'Baya';

/// A baya weaver in flight: one ink silhouette, the wing and its feathers
/// set apart by thin cuts. The paths come from branding/generate.py
/// (108-unit grid).
///
/// [tile] draws it ink on its light tile, as on the launcher; without one
/// the bird takes the text colour and its cuts the page colour.
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
          ink: tile ? AppBrandColors.ink : colors.text,
          paper: tile ? AppBrandColors.tile : colors.bg,
        ),
      ),
    );
  }
}

/// "Baya" in its script face, beside the mark.
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
  const AppMarkPainter({
    required this.tile,
    required this.ink,
    required this.paper,
  });

  final bool tile;
  final Color ink;

  /// The colour behind the bird, which its cuts show through to.
  final Color paper;

  static final _body = _parse(kMarkBody);
  static final _wing = _parse(kMarkWing);
  static final _cuts = [for (final cut in kMarkCuts) _parse(cut)];

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
        Paint()..color = paper,
      );
    }
    canvas
      ..translate(54, 54)
      ..scale(kMarkScale)
      ..translate(-54 + kMarkShift.$1, -54 + kMarkShift.$2);
    final fill = Paint()..color = ink;
    final cut = Paint()
      ..color = paper
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final (cx, cy, r) = kMarkEye;
    canvas
      ..drawPath(_body, fill)
      ..drawPath(_wing, cut..strokeWidth = kMarkWingGap)
      ..drawPath(_wing, fill);
    cut.strokeWidth = kMarkCutWidth;
    for (final line in _cuts) {
      canvas.drawPath(line, cut);
    }
    canvas
      ..drawCircle(Offset(cx, cy), r, Paint()..color = paper)
      ..restore();
  }

  /// Reads absolute M, L, C and Z commands, all the mark uses.
  static Path _parse(String data) {
    final path = Path();
    final tokens = RegExp(r'[MLCZ]|-?\d*\.?\d+')
        .allMatches(data)
        .map((m) => m[0]!)
        .toList();
    var i = 0;
    double next() => double.parse(tokens[i++]);
    var command = 'M';
    while (i < tokens.length) {
      if (RegExp('[MLCZ]').hasMatch(tokens[i])) command = tokens[i++];
      switch (command) {
        case 'M':
          path.moveTo(next(), next());
          command = 'L';
        case 'L':
          path.lineTo(next(), next());
        case 'C':
          path.cubicTo(next(), next(), next(), next(), next(), next());
        case 'Z':
          path.close();
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(AppMarkPainter old) =>
      old.tile != tile || old.ink != ink || old.paper != paper;
}
