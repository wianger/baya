import 'package:flutter/material.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/themes/themes.dart';

const kAppName = 'Baya';

/// A weaverbird gathers devices, workspaces and conversations into one place.
/// Geometry matches branding/baya-mark.svg and the Android vector icons: a
/// translucent glass tile carrying a filled graphite-teal bird with one gold
/// accent. The silhouette stays recognizable from launcher to sidebar sizes.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 28, this.tile = false});
  final double size;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mark = CustomPaint(
      size: Size.square(size),
      painter: AppMarkPainter(
        foreground: tile
            ? dark
                  ? colors.text
                  : AppBrandColors.foreground
            : colors.text.withValues(alpha: .88),
        foregroundLight: tile
            ? dark
                  ? colors.text.withValues(alpha: .78)
                  : AppBrandColors.foregroundLight
            : colors.text.withValues(alpha: .72),
        highlight: tile
            ? dark
                  ? AppBrandColors.highlightLight
                  : AppBrandColors.highlight
            : colors.accent,
        bodyShadow: tile
            ? AppBrandColors.shadow.withValues(alpha: dark ? .44 : .24)
            : colors.text.withValues(alpha: 0),
        bodyRim: tile
            ? colors.glassHighlight.withValues(alpha: dark ? .34 : .58)
            : colors.text.withValues(alpha: .12),
        cutout: tile
            ? Color.alphaBlend(
                colors.glassHighlight.withValues(alpha: dark ? .34 : .82),
                colors.inputFill.withValues(alpha: dark ? .28 : .16),
              )
            : colors.bg,
        // The negative-space wing thickens slightly when scaled down.
        weight: size < 56 ? 1.22 : 1,
      ),
    );
    return Semantics(
      label: kAppName,
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: tile
            ? BayaGlassSurface(
                role: BayaGlassRole.brand,
                radius: size * .22,
                elevated: size >= 52,
                blurSigma: size >= 52 ? 30 : 16,
                child: Padding(
                  padding: EdgeInsets.all(size * .13),
                  child: SizedBox.square(
                    dimension: size * .74,
                    child: FittedBox(child: mark),
                  ),
                ),
              )
            : mark,
      ),
    );
  }
}

class AppMarkPainter extends CustomPainter {
  const AppMarkPainter({
    required this.foreground,
    required this.foregroundLight,
    required this.highlight,
    required this.bodyShadow,
    required this.bodyRim,
    this.background,
    this.backgroundEnd,
    this.edge,
    required this.cutout,
    this.weight = 1,
  });

  final Color foreground;
  final Color foregroundLight;
  final Color highlight;
  final Color bodyShadow;
  final Color bodyRim;
  final Color cutout;
  final Color? background, backgroundEnd, edge;
  final double weight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 108, size.height / 108);
    const bounds = Rect.fromLTWH(0, 0, 108, 108);
    final background = this.background;
    if (background != null) {
      final tile = RRect.fromRectAndRadius(bounds, const Radius.circular(24));
      final surface = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [background, backgroundEnd ?? background],
        ).createShader(bounds);
      canvas.drawRRect(tile, surface);
      if (edge case final line?) {
        canvas.drawRRect(
          tile.deflate(0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = line,
        );
      }
    }

    // Speech-bubble body that doubles as the bird's breast.
    final body = Path()
      ..moveTo(28, 65)
      ..cubicTo(28, 54, 37, 46, 48, 46)
      ..cubicTo(48, 32, 57, 24, 68, 26)
      ..cubicTo(79, 27, 83, 38, 79, 48)
      ..cubicTo(79, 65, 65, 79, 48, 79)
      ..lineTo(28, 86)
      ..lineTo(32, 74)
      ..cubicTo(29, 71, 28, 68, 28, 65)
      ..close();
    if (bodyShadow.a > 0) {
      canvas.drawShadow(body, bodyShadow, 7, false);
    }
    final bodyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [foregroundLight, foreground],
      ).createShader(body.getBounds());
    canvas.drawPath(body, bodyPaint);
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8
        ..strokeJoin = StrokeJoin.round
        ..color = bodyRim,
    );

    canvas.save();
    canvas.clipPath(body);
    canvas.drawOval(
      Rect.fromLTWH(31, 30, 45, 17),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            bodyRim.withValues(alpha: bodyRim.a * .58),
            bodyRim.withValues(alpha: 0),
          ],
        ).createShader(const Rect.fromLTWH(31, 30, 45, 17)),
    );
    canvas.restore();

    // A single negative-space feather keeps the mark readable at small sizes.
    canvas.drawPath(
      Path()
        ..moveTo(42, 59)
        ..cubicTo(50, 66, 61, 66, 71, 57)
        ..cubicTo(68, 68, 56, 74, 45, 70),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.2 * weight
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = cutout,
    );

    // The gold beak is the only non-neutral color in the mark.
    final beak = Path()
      ..moveTo(80, 42.5)
      ..lineTo(94, 48)
      ..lineTo(79.5, 53.5)
      ..close();
    if (bodyShadow.a > 0) {
      canvas.drawShadow(beak, bodyShadow, 3, false);
    }
    canvas.drawPath(beak, Paint()..color = highlight);

    canvas.drawCircle(
      const Offset(72, 39.5),
      2.8 + (weight - 1) * 1.2,
      Paint()..color = cutout,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(AppMarkPainter old) =>
      old.foreground != foreground ||
      old.foregroundLight != foregroundLight ||
      old.highlight != highlight ||
      old.bodyShadow != bodyShadow ||
      old.bodyRim != bodyRim ||
      old.background != background ||
      old.backgroundEnd != backgroundEnd ||
      old.edge != edge ||
      old.cutout != cutout ||
      old.weight != weight;
}
