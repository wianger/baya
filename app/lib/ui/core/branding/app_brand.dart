import 'package:app/ui/core/branding/mark_geometry.g.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

const kAppName = 'Baya';

/// A perched baya weaver, drawn as magpie draws its icon: one ink
/// silhouette with white cut in for the crown, breast, wing and tail. The
/// paths come from branding/generate.py (108-unit grid).
///
/// [tile] draws it on its grey tile, as on the launcher; without one the
/// bird takes the text colour and its white parts the page colour.
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
          paper: tile ? AppBrandColors.paper : colors.bg,
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

  /// The white of the drawing: crown, breast, feather lines.
  final Color paper;

  static final _body = _parse(kMarkBody);
  static final _breast = _parse(kMarkBreast);
  static final _crown = _parse(kMarkCrown);
  static final _wing = _parse(kMarkWing);
  static final _lines = [for (final line in kMarkLines) _parse(line)];

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
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(kMarkTile.$1), Color(kMarkTile.$2)],
          ).createShader(const Rect.fromLTWH(0, 0, 108, 108)),
      );
    }
    canvas
      ..translate(54, 54)
      ..scale(kMarkScale)
      ..translate(-kMarkCenter.$1, -kMarkCenter.$2);
    final fill = Paint()..color = ink;
    final white = Paint()..color = paper;
    final edge = Paint()
      ..color = paper
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final (ex, ey, ring, pupil) = kMarkEye;
    canvas
      ..drawPath(_body, fill)
      ..drawPath(_breast, white)
      ..drawPath(_crown, white)
      ..drawPath(_wing, fill)
      ..drawPath(_wing, edge..strokeWidth = kMarkWingEdge);
    edge.strokeWidth = kMarkLineWidth;
    for (final line in _lines) {
      canvas.drawPath(line, edge);
    }
    canvas
      ..drawCircle(Offset(ex, ey), ring, white)
      ..drawCircle(Offset(ex + .3, ey), pupil, fill)
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
