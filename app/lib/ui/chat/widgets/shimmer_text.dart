import 'package:flutter/material.dart';

/// Text with a light sweeping across it: the agent is busy with this line.
class ShimmerText extends StatefulWidget {
  const ShimmerText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base =
        widget.style.color ?? DefaultTextStyle.of(context).style.color!;
    final bright = Color.lerp(
      base,
      Theme.of(context).colorScheme.onSurface,
      .9,
    )!;
    final text = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
    if (MediaQuery.of(context).disableAnimations) return text;
    return AnimatedBuilder(
      animation: _sweep,
      child: text,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) {
          final t = _sweep.value * 2 - .5;
          return LinearGradient(
            colors: [base, bright, base],
            stops: [
              (t - .25).clamp(0.0, 1.0),
              t.clamp(0.0, 1.0),
              (t + .25).clamp(0.0, 1.0),
            ],
          ).createShader(bounds);
        },
        child: child,
      ),
    );
  }
}
