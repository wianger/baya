import 'dart:async';
import 'dart:math' as math;

import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Height a held row gained (or lost) since the scroll position last made
/// up for it.
class ChatScrollAnchor {
  double _shift = 0;

  void add(double delta) => _shift += delta;

  double take() {
    final shift = _shift;
    _shift = 0;
    return shift;
  }
}

/// The chat's scrolling, plus: what a held row grows by, the scroll offset
/// grows by, in the same layout. The chat is reversed, so a row's bottom
/// edge stays put and its top (the header someone tapped) would move.
class AnchoredScrollPhysics extends ScrollPhysics {
  const AnchoredScrollPhysics(this.anchor, {super.parent});

  final ChatScrollAnchor anchor;

  @override
  AnchoredScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      AnchoredScrollPhysics(anchor, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final base = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    final shift = anchor.take();
    if (shift == 0) return base;
    // A different position makes the viewport lay out again this frame, so
    // the header never shows out of place.
    return (base + shift).clamp(
      newPosition.minScrollExtent,
      math.max(newPosition.minScrollExtent, newPosition.maxScrollExtent),
    );
  }
}

/// Gives rows below it the chat's [ChatScrollAnchor].
class ChatScrollAnchorScope extends InheritedWidget {
  const ChatScrollAnchorScope({
    super.key,
    required this.anchor,
    required super.child,
  });

  final ChatScrollAnchor anchor;

  static ChatScrollAnchor? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatScrollAnchorScope>()?.anchor;

  @override
  bool updateShouldNotify(ChatScrollAnchorScope old) => old.anchor != anchor;
}

/// One chat row. While held, its change in height moves the scroll offset
/// with it, so what was tapped stays under the finger as the row opens or
/// closes. Streaming text, which should grow upward, never holds a row.
class HoldInPlace extends StatefulWidget {
  const HoldInPlace({super.key, required this.child});

  final Widget child;

  /// Hold the row around [context] through the open or close it starts.
  static void hold(BuildContext context) =>
      context.findAncestorStateOfType<_HoldInPlaceState>()?._hold();

  @override
  State<HoldInPlace> createState() => _HoldInPlaceState();
}

class _HoldInPlaceState extends State<HoldInPlace> {
  bool _held = false;
  Timer? _release;

  void _hold() {
    _release?.cancel();
    if (!_held) setState(() => _held = true);
    _release = Timer(
      BayaMotion.emphasized + const Duration(milliseconds: 120),
      () {
        if (mounted) setState(() => _held = false);
      },
    );
  }

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Hold(
    anchor: ChatScrollAnchorScope.maybeOf(context),
    held: _held,
    child: widget.child,
  );
}

class _Hold extends SingleChildRenderObjectWidget {
  const _Hold({required this.anchor, required this.held, super.child});

  final ChatScrollAnchor? anchor;
  final bool held;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHold(anchor, held);

  @override
  void updateRenderObject(BuildContext context, _RenderHold renderObject) {
    renderObject
      ..anchor = anchor
      ..held = held;
  }
}

class _RenderHold extends RenderProxyBox {
  _RenderHold(this.anchor, this.held);

  ChatScrollAnchor? anchor;
  bool held;

  @override
  void performLayout() {
    final before = hasSize ? size.height : null;
    super.performLayout();
    if (!held || before == null) return;
    final delta = size.height - before;
    if (delta != 0) anchor?.add(delta);
  }
}

/// What a disclosure in a chat row shows when open, in place at once.
///
/// Not an AnimatedSize: the chat list moves and re-attaches rows while it
/// updates, and an AnimatedSize detached mid-animation stops its controller
/// and, back in its stable state, never resumes, keeping the height it had
/// (a closed thought leaving its open height blank). The row changes height
/// in one frame instead, and [HoldInPlace] keeps the header where it was.
class DisclosureBody extends StatelessWidget {
  const DisclosureBody({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
