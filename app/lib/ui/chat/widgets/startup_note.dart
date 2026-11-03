import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What the agent printed as it started, folded into one quiet line.
class StartupNoteRow extends StatefulWidget {
  const StartupNoteRow({super.key, required this.text});

  final String text;

  @override
  State<StartupNoteRow> createState() => _StartupNoteRowState();
}

class _StartupNoteRowState extends State<StartupNoteRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('startup-note'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.info, size: 15, color: colors.muted),
                const SizedBox(width: 8),
                Text(
                  context.l10n.agentStartupNotes,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colors.muted2,
                  ),
                ),
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
            ),
          ),
        ),
        AnimatedSize(
          duration: BayaMotion.standard,
          curve: BayaMotion.enter,
          alignment: Alignment.topLeft,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(left: 9, top: 2, bottom: 6),
                  padding: const EdgeInsets.only(left: 14),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: colors.border, width: 1.5),
                    ),
                  ),
                  child: AgentMarkdown(
                    widget.text,
                    selectable: true,
                    fontSize: 13.5,
                    color: colors.muted2,
                  ),
                ),
        ),
      ],
    );
  }
}
