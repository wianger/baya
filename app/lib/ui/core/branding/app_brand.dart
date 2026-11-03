import 'package:app/ui/core/branding/mark_geometry.g.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

const kAppName = 'Baya';

/// A baya weaver in flight, straw gold, the far wing a shade deeper. The
/// paths come from branding/generate.py (108-unit grid).
///
/// [tile] draws it on its graphite tile, as on the launcher; without one the
/// bird sits on the page with its eye cut through.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 28, this.tile = false});
  final double size;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: kAppName,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: AppMarkPainter(tile: tile),
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
  const AppMarkPainter({required this.tile});

  final bool tile;

  static final _body = _parse(kMarkBody);
  static final _nearWing = _parse(kMarkNearWing);
  static final _farWing = _parse(kMarkFarWing);

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
    canvas.translate(kMarkShift.$1, kMarkShift.$2);
    final (x1, y1, x2, y2) = kMarkGradient;
    final straw = Paint()
      ..shader = const LinearGradient(
        colors: [AppBrandColors.strawLight, AppBrandColors.strawDeep],
      ).createShader(Rect.fromPoints(Offset(x1, y1), Offset(x2, y2)));
    final (cx, cy, r) = kMarkEye;
    final eye = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas
      ..drawPath(_farWing, Paint()..color = AppBrandColors.strawDeep)
      ..drawPath(Path.combine(PathOperation.difference, _body, eye), straw)
      ..drawPath(_nearWing, straw)
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
  bool shouldRepaint(AppMarkPainter old) => old.tile != tile;
}
