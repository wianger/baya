import 'dart:math' as math;

import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';

/// Returns the visible global bounds of [context]'s render object.
///
/// Callers use this from an action callback, before pushing the popover route,
/// so the transition can grow directly out of the control the user tapped.
Rect? bayaRectOf(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) return null;
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

/// Presents a popover that grows from the tapped control into a page anchored
/// at the upper-right of the screen.
///
/// The final position deliberately overlaps the floating chat header so the
/// transition reads as one surface replacing the button instead of a detached
/// card fading in below it.
Future<T?> showBayaTopRightPopover<T>({
  required BuildContext context,
  required Widget child,
  Rect? origin,
  double width = 280,
}) {
  final media = MediaQuery.of(context);
  final reduceMotion = media.disableAnimations;
  final safe = media.padding;
  final fallbackSize = math.max(40.0, media.size.shortestSide * .1);
  final resolvedOrigin =
      origin ??
      Rect.fromLTWH(
        media.size.width - safe.right - fallbackSize - 8,
        safe.top + 8,
        fallbackSize,
        fallbackSize,
      );
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: .06),
    transitionDuration: reduceMotion ? Duration.zero : BayaMotion.morph,
    pageBuilder: (dialogContext, animation, _) => _BayaTopRightMorph(
      animation: animation,
      origin: resolvedOrigin,
      requestedWidth: width,
      reduceMotion: reduceMotion,
      child: child,
    ),
    transitionBuilder: (_, _, _, child) => child,
  );
}

class _BayaTopRightMorph extends StatelessWidget {
  const _BayaTopRightMorph({
    required this.animation,
    required this.origin,
    required this.requestedWidth,
    required this.reduceMotion,
    required this.child,
  });

  final Animation<double> animation;
  final Rect origin;
  final double requestedWidth;
  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final safe = media.padding;
    const edgeInset = 12.0;
    final targetRight =
        media.size.width - math.max(edgeInset, safe.right + edgeInset);
    final availableWidth = math.max(
      120.0,
      targetRight - safe.left - (edgeInset * 2),
    );
    final targetWidth = math.min(requestedWidth, availableWidth);
    final targetLeft = math.max(
      safe.left + edgeInset,
      targetRight - targetWidth,
    );
    final targetTop = math.max(safe.top + 8, origin.top);
    final maxHeight = math.max(
      160.0,
      media.size.height - targetTop - safe.bottom - edgeInset,
    );
    final startScale = (origin.width / targetWidth).clamp(.12, 1.0);
    final geometry = CurvedAnimation(
      parent: animation,
      curve: BayaMotion.morphSettle,
      reverseCurve: BayaMotion.exit,
    );
    final content = reduceMotion
        ? const AlwaysStoppedAnimation<double>(1)
        : TweenSequence<double>([
            TweenSequenceItem(tween: ConstantTween<double>(0), weight: 18),
            TweenSequenceItem(
              tween: Tween<double>(
                begin: 0,
                end: 1,
              ).chain(CurveTween(curve: BayaMotion.enter)),
              weight: 38,
            ),
            TweenSequenceItem(tween: ConstantTween<double>(1), weight: 44),
          ]).animate(animation);

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: targetTop,
            left: targetLeft,
            width: targetWidth,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: AnimatedBuilder(
                animation: geometry,
                child: BayaSurfaceContentMotion(
                  animation: content,
                  child: child,
                ),
                builder: (context, child) {
                  final progress = reduceMotion ? 1.0 : geometry.value;
                  final scale = startScale + (1 - startScale) * progress;
                  final offset = Offset(
                    (origin.right - targetRight) * (1 - progress),
                    (origin.top - targetTop) * (1 - progress),
                  );
                  return IgnorePointer(
                    ignoring: progress < .82,
                    child: RepaintBoundary(
                      child: Transform.translate(
                        offset: offset,
                        child: Transform.scale(
                          key: const ValueKey('baya-top-right-morph-transform'),
                          alignment: Alignment.topRight,
                          scale: scale,
                          child: child,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
