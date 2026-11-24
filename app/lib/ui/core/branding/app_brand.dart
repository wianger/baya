import 'package:app/ui/core/branding/mark_geometry.g.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

const kAppName = 'Baya';

/// A perched baya weaver as one flat silhouette, drawn the way DeepSeek
/// draws its whale: a few large curves, the wing and eye cut out, and the
/// weaver's curled crest. The paths come from branding/generate.py
/// (108-unit grid).
///
/// [tile] draws it white on a black tile, as on the launcher; without one
/// the bird takes the text colour and its cut-outs show the page.
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
          ink: tile ? AppBrandColors.paper : colors.text,
        ),
      ),
    );
  }
}

/// "Baya" in its wordmark face, beside the mark.
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
  const AppMarkPainter({required this.tile, required this.ink});

  final bool tile;
  final Color ink;

  static final _bird = () {
    final (ex, ey, r) = kMarkEye;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(_parse(kMarkBird), Offset.zero)
      ..addPath(_parse(kMarkWing), Offset.zero)
      ..addOval(Rect.fromCircle(center: Offset(ex, ey), radius: r));
  }();

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
        Paint()..color = const Color(kMarkInk),
      );
    }
    canvas
      ..translate(54, 54)
      ..scale(kMarkScale)
      ..translate(-kMarkCenter.$1, -kMarkCenter.$2)
      ..drawPath(_bird, Paint()..color = ink)
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
  bool shouldRepaint(AppMarkPainter old) => old.tile != tile || old.ink != ink;
}
