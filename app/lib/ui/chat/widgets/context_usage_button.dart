import 'package:app/data/hosts/session_controller.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/session_settings_sheet.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// A ring showing how full the agent's context is (ACP `usage_update`).
/// Unknown usage is never shown as zero. Opens the session settings.
class ContextUsageButton extends StatelessWidget {
  const ContextUsageButton({super.key, required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final usage = context.watch<SessionController>().usage;
    final fraction = enabled ? usage?.fraction : null;
    final colors = context.colors;
    final label = fraction == null
        ? context.l10n.notReported
        : '${(fraction * 100).toStringAsFixed(1)}%';
    return Semantics(
      value: label,
      child: IconButton(
        key: const Key('context-usage'),
        tooltip: context.l10n.sessionSettings,
        onPressed: enabled ? () => showSessionSettings(context) : null,
        icon: ExcludeSemantics(
          child: SizedBox.square(
            dimension: 32,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.border, width: 2.5),
                    ),
                  ),
                ),
                if (fraction != null)
                  Positioned.fill(
                    child: CircularProgressIndicator(
                      value: fraction,
                      strokeWidth: 2.5,
                      strokeAlign: -1,
                      strokeCap: StrokeCap.round,
                      color: colors.accent,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(5),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      fraction == null ? '—' : '${(fraction * 100).round()}%',
                      style: context.typo.sansBody.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: enabled ? colors.text : colors.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
