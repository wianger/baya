import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/shimmer_text.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/copy_button.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The agent's reasoning. While it streams, it runs through a short window
/// that keeps scrolling to the newest line, the oldest fading out at the top;
/// once done it folds to one line saying how long it took (when this phone
/// watched it happen) and opens in place as Markdown. It shows only what the
/// agent sent.
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({
    super.key,
    required this.text,
    required this.complete,
    this.id,
  });
  final String text;
  final bool complete;

  /// The message id, so a duration survives the row scrolling away.
  final String? id;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  static final _durations = <String, Duration>{};
  final _watch = Stopwatch();
  bool _open = false;

  @override
  void initState() {
    super.initState();
    if (!widget.complete) _watch.start();
  }

  @override
  void didUpdateWidget(ThinkingBlock old) {
    super.didUpdateWidget(old);
    if (widget.complete && !old.complete && _watch.isRunning) {
      _watch.stop();
      if (widget.id case final id?) _durations[id] = _watch.elapsed;
    }
  }

  Duration? get _took {
    if (widget.id case final id?) {
      if (_durations[id] case final known?) return known;
    }
    return widget.complete && _watch.elapsedMilliseconds > 0
        ? _watch.elapsed
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = widget.text.trim();
    final style = context.typo.sansBody.copyWith(
      fontSize: 14,
      color: colors.muted2,
      fontWeight: FontWeight.w500,
    );
    final took = _took;
    final label = !widget.complete
        ? context.l10n.thinking
        : took != null && took.inSeconds >= 1
        ? context.l10n.thoughtFor(took.inSeconds)
        : context.l10n.thoughtProcess;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('thinking-disclosure'),
          borderRadius: BorderRadius.circular(10),
          onTap: text.isEmpty ? null : () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.sparkle, size: 15, color: colors.muted),
                const SizedBox(width: 8),
                Flexible(
                  child: widget.complete
                      ? Text(label, style: style)
                      : ShimmerText(label, style: style),
                ),
                if (text.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _open ? .25 : 0,
                    duration: BayaMotion.fast,
                    child: Icon(
                      LucideIcons.chevronRight,
                      size: 15,
                      color: colors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!widget.complete && !_open && text.isNotEmpty)
          _ThoughtWindow(text: text),
        AnimatedSize(
          duration: BayaMotion.standard,
          curve: BayaMotion.enter,
          alignment: Alignment.topLeft,
          child: !_open || text.isEmpty
              ? const SizedBox(width: double.infinity)
              : Container(
                  key: const ValueKey('thinking-detail'),
                  width: double.infinity,
                  margin: const EdgeInsets.only(left: 9, top: 2, bottom: 6),
                  padding: const EdgeInsets.only(left: 14),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: colors.border, width: 1.5),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KeyedSubtree(
                        key: const ValueKey('thinking-detail-text'),
                        child: AgentMarkdown(
                          text,
                          selectable: widget.complete,
                          fontSize: 14,
                          color: colors.muted2,
                        ),
                      ),
                      if (widget.complete)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: BayaCopyButton(
                            key: const ValueKey('thinking-copy'),
                            text: text,
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// A few lines tall: streamed thought scrolls up through it smoothly, the
/// newest line at the bottom and the oldest fading out at the top.
class _ThoughtWindow extends StatefulWidget {
  const _ThoughtWindow({required this.text});

  final String text;

  @override
  State<_ThoughtWindow> createState() => _ThoughtWindowState();
}

class _ThoughtWindowState extends State<_ThoughtWindow> {
  static const _lines = 6;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Opens on the newest line, not the oldest.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void didUpdateWidget(_ThoughtWindow old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
  }

  void _follow() {
    if (!mounted || !_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (end <= _scroll.offset) return;
    if (MediaQuery.of(context).disableAnimations) {
      _scroll.jumpTo(end);
    } else {
      _scroll.animateTo(
        end,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = context.typo.sansBody.copyWith(
      fontSize: 13.5,
      height: 1.55,
      color: colors.muted2,
    );
    final lineHeight = style.fontSize! * style.height!;
    return Container(
      key: const ValueKey('thinking-window'),
      margin: const EdgeInsets.only(left: 9, top: 2, bottom: 6),
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.border, width: 1.5)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: lineHeight * _lines),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black, Colors.black],
            stops: [0, .35, 1],
          ).createShader(bounds),
          child: SingleChildScrollView(
            controller: _scroll,
            physics: const NeverScrollableScrollPhysics(),
            child: Text(widget.text, style: style),
          ),
        ),
      ),
    );
  }
}
