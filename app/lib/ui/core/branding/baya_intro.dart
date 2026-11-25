/// The opening, as Claude's: the mark and the name, centred on the page
/// colour where Android's launch screen left the bird, then the app comes
/// up through them.
library;

import 'dart:async';

import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

class BayaIntro extends StatefulWidget {
  const BayaIntro({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// Off in tests and when the system asks for less motion.
  final bool enabled;

  @override
  State<BayaIntro> createState() => _BayaIntroState();
}

class _BayaIntroState extends State<BayaIntro>
    with SingleTickerProviderStateMixin {
  /// 0 → 1: the name writes in beside the bird; 1 → 2: the page lifts away.
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
    upperBound: 2,
  );
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      _done = true;
      return;
    }
    unawaited(
      _controller
          .animateTo(1, duration: const Duration(milliseconds: 520))
          .then((_) => Future<void>.delayed(const Duration(milliseconds: 260)))
          .then((_) {
            if (!mounted) return Future<void>.value();
            return _controller.animateTo(
              2,
              duration: const Duration(milliseconds: 420),
            );
          })
          .then((_) {
            if (mounted) setState(() => _done = true);
          }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_done && MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _done = true;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final colors = context.colors;
    return Stack(
      children: [
        // The app underneath settles in as the cover lifts.
        AnimatedBuilder(
          animation: _controller,
          child: widget.child,
          builder: (_, child) {
            final t = Curves.easeOutCubic.transform(
              (_controller.value - 1).clamp(0.0, 1.0),
            );
            return Transform.scale(scale: .97 + .03 * t, child: child);
          },
        ),
        AnimatedBuilder(
          animation: _controller,
          builder: (_, _) {
            final write = Curves.easeOutCubic.transform(
              _controller.value.clamp(0.0, 1.0),
            );
            final lift = Curves.easeInCubic.transform(
              (_controller.value - 1).clamp(0.0, 1.0),
            );
            return IgnorePointer(
              child: Opacity(
                opacity: 1 - lift,
                child: ColoredBox(
                  color: colors.bg,
                  child: Center(
                    child: Transform.scale(
                      scale: 1 + .06 * lift,
                      child: Row(
                        key: const Key('baya-intro'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AppMark(size: 52),
                          // The name opens out from behind the bird.
                          ClipRect(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              widthFactor: write,
                              child: Opacity(
                                opacity: write,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 10),
                                  child: Text(
                                    kAppName,
                                    style: brandDisplayTextStyle(
                                      fontSize: 46,
                                      color: colors.text,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
