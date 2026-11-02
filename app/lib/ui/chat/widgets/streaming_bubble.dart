import 'dart:math' as math;

import 'package:app/l10n/l10n.dart';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';

// StreamingBubble shows the assistant's growing response and a blinking
// cursor. Before the first text chunk arrives, an animated working row keeps
// the active turn visible at the latest position in the transcript.
// The buffer is already batched with 16ms debounce in SessionRepository.

class StreamingBubble extends StatelessWidget {
  final StreamingMessage streaming;
  const StreamingBubble(this.streaming, {super.key});

  @override
  Widget build(BuildContext context) {
    final hasText = streaming.buffer.isNotEmpty;
    if (!hasText) return const AgentWorkingIndicator();
    // Full content width (matches AssistantBubble). Cursor lives on its OWN
    // line directly below the response (never inline beside wrapped text,
    // which made it float toward the middle).
    return BayaReveal(
      offset: 5,
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Render partial markdown live; not selectable while it changes.
            AgentMarkdown(streaming.buffer),
            const _BlinkingCursor(),
          ],
        ),
      ),
    );
  }
}

class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor();

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blink,
      builder: (context, _) => Container(
        key: const Key('streaming-cursor'),
        width: 3,
        height: 16,
        margin: const EdgeInsets.only(left: 2, top: 3, bottom: 1),
        decoration: BoxDecoration(
          color: context.colors.accent.withValues(
            alpha: _blink.value < 0.5 ? 1 : 0.18,
          ),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Compact three-dot indicator shown whenever an agent turn is active but no
/// response text is currently streaming. It is also used for an empty stream
/// before the first chunk, so tool calls and pre-output gaps retain a visible
/// loading state at the newest transcript position.
class AgentWorkingIndicator extends StatefulWidget {
  const AgentWorkingIndicator({super.key});

  @override
  State<AgentWorkingIndicator> createState() => _AgentWorkingIndicatorState();
}

class _AgentWorkingIndicatorState extends State<AgentWorkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      label: context.l10n.agentIsWorking,
      container: true,
      child: ExcludeSemantics(
        child: Align(
          alignment: Alignment.centerLeft,
          child: BayaGlassSurface(
            radius: 18,
            elevated: false,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: SizedBox(
              key: const Key('agent-working-indicator'),
              width: 38,
              height: 8,
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) => Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(3, (index) {
                    final phase = (_pulse.value + index * .18) % 1;
                    final lift = (math.sin(phase * math.pi * 2) + 1) / 2;
                    return Transform.translate(
                      key: ValueKey('agent-working-dot-$index'),
                      offset: Offset(0, -2.4 * lift),
                      child: Opacity(
                        opacity: .42 + .58 * lift,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.working,
                            shape: BoxShape.circle,
                          ),
                          child: const SizedBox.square(dimension: 6),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
