import 'dart:math' as math;

import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';

/// Three pulsing dots: the agent is working and has not started a reply.
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
          child: BayaSurface(
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
