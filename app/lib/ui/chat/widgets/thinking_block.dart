import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/shimmer_text.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/copy_button.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The agent's reasoning as one quiet line that opens in place. It shows only
/// what the agent sent; with nothing sent there is nothing to open.
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({super.key, required this.text, required this.complete});
  final String text;
  final bool complete;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = widget.text.trim();
    final style = context.typo.sansBody.copyWith(
      fontSize: 14,
      color: colors.muted2,
      fontWeight: FontWeight.w500,
    );
    final label = widget.complete
        ? context.l10n.thoughtProcess
        : context.l10n.thinking;
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
                      SelectableText(
                        text,
                        key: const ValueKey('thinking-detail-text'),
                        style: context.typo.sansBody.copyWith(
                          fontSize: 14,
                          height: 1.55,
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
