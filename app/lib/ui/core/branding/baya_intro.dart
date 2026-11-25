/// The opening. Android's launch screen leaves the bird alone in the middle,
/// at this same size; the bird steps aside as the name writes in beside it,
/// large, as Claude's launch shows them; then the two glide into the home's
/// arrangement, the bird above and the name below, smaller, and the home
/// comes up around them.
library;

import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Where the home draws its mark and name (session_overview.dart): the
/// sizes, and the gap between them.
const kHomeMarkSize = 64.0;
const kHomeWordmarkSize = 44.0;
const kHomeMarkGap = 10.0;

/// The bird Android's launch screen draws (branding/generate.py SPLASH_SCALE).
const kLaunchMarkSize = 80.0;

class BayaIntro extends StatefulWidget {
  const BayaIntro({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// Off in tests.
  final bool enabled;

  @override
  State<BayaIntro> createState() => _BayaIntroState();
}

class _BayaIntroState extends State<BayaIntro>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// The bird steps aside and the name writes in.
  late final _enter = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
    duration: const Duration(milliseconds: 520),
  );

  /// Row → column.
  late final _move = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
    duration: const Duration(milliseconds: 620),
  );

  /// The cover lifts off the home.
  late final _lift = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
    duration: const Duration(milliseconds: 320),
  );
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      _done = true;
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run());
  }

  DateTime? _left;

  /// Coming back after a while plays the opening again, as a launch does;
  /// a quick switch away and back does not.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden) _left ??= DateTime.now();
    if (state != AppLifecycleState.resumed) return;
    final away = _left == null
        ? Duration.zero
        : DateTime.now().difference(_left!);
    _left = null;
    if (away < const Duration(seconds: 30) || !_done) return;
    _enter.value = 0;
    _move.value = 0;
    _lift.value = 0;
    setState(() => _done = false);
    unawaited(_run());
  }

  Future<void> _run() async {
    // The first frames repeat the launch screen exactly: no jump.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    await _enter.forward();
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (!mounted) return;
    await _move.forward();
    if (!mounted) return;
    await _lift.forward();
    if (mounted) setState(() => _done = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _enter.dispose();
    _move.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final colors = context.colors;
    final media = MediaQuery.of(context);
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge([_enter, _move, _lift]),
              builder: (context, _) {
                final enter = Curves.easeOutCubic.transform(_enter.value);
                final move = Curves.easeInOutCubic.transform(_move.value);
                final lift = Curves.easeOut.transform(_lift.value);
                // Sizes: large in the row, the home's in the column.
                final mark = lerpDouble(kLaunchMarkSize, kHomeMarkSize, move)!;
                final word = lerpDouble(64, kHomeWordmarkSize, move)!;
                final style = brandDisplayTextStyle(
                  fontSize: word,
                  color: colors.text,
                );
                final text = TextPainter(
                  text: TextSpan(text: kAppName, style: style),
                  textDirection: TextDirection.ltr,
                )..layout();
                // Measured, then let go: only the numbers are kept.
                final wordWidth = text.width;
                final wordHeight = text.height;
                text.dispose();
                final size = media.size;
                // The row sits mid-screen; the column where the home has it:
                // centred below its header (68).
                final rowCenter = Offset(size.width / 2, size.height / 2);
                final columnCenter = Offset(
                  size.width / 2,
                  (media.padding.top +
                          68 +
                          size.height -
                          media.padding.bottom) /
                      2,
                );
                final center = Offset.lerp(rowCenter, columnCenter, move)!;
                const rowGap = 14.0;
                final rowWidth = mark + rowGap + wordWidth;
                final columnHeight = mark + kHomeMarkGap + wordHeight;
                // Mark: left of the row → top of the column.
                // Alone at first, where the launch screen drew it; then left,
                // making room for the name.
                final markRow = Offset(
                  lerpDouble(
                    center.dx,
                    center.dx - rowWidth / 2 + mark / 2,
                    enter,
                  )!,
                  center.dy,
                );
                final markColumn = Offset(
                  center.dx,
                  center.dy - columnHeight / 2 + mark / 2,
                );
                final markAt = Offset.lerp(markRow, markColumn, move)!;
                // Name: right of the row → under the mark.
                final wordRow = Offset(
                  center.dx + rowWidth / 2 - wordWidth / 2,
                  center.dy,
                );
                final wordColumn = Offset(
                  center.dx,
                  center.dy + columnHeight / 2 - wordHeight / 2,
                );
                final wordAt = Offset.lerp(wordRow, wordColumn, move)!;
                // Above the pages, so no Material of theirs: without one the
                // name would wear Flutter's "missing Material" underline.
                return Opacity(
                  opacity: 1 - lift,
                  child: Material(
                    type: MaterialType.transparency,
                    child: Stack(
                      key: const Key('baya-intro'),
                      children: [
                        Positioned.fill(child: ColoredBox(color: colors.bg)),
                        Positioned(
                          left: markAt.dx - mark / 2,
                          top: markAt.dy - mark / 2,
                          child: AppMark(size: mark),
                        ),
                        Positioned(
                          left: wordAt.dx - wordWidth / 2,
                          top: wordAt.dy - wordHeight / 2,
                          // Written in from the bird's side.
                          child: ClipRect(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              widthFactor: Curves.easeOut.transform(enter),
                              child: Opacity(
                                opacity: enter,
                                child: Text(kAppName, style: style),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
