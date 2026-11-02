import 'package:app/ui/chat/widgets/baya_activity_card.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/copy_button.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Quiet disclosure for agent-provided thinking; it never invents content.
class ThinkingBlock extends StatelessWidget {
  const ThinkingBlock({super.key, required this.text, required this.complete});
  final String text;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final content = text.trim();
    final title = complete ? context.l10n.thoughtProcess : 'Thinking…';
    return BayaActivityCard(
      disclosureKey: const ValueKey('thinking-disclosure'),
      leading: complete
          ? Icon(LucideIcons.brain, size: 18, color: colors.muted2)
          : SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: colors.muted2,
              ),
            ),
      title: title,
      preview: _preview(content),
      onTap: content.isEmpty
          ? null
          : () => showBayaActivityDetailSheet(
              context,
              title: title,
              child: _ThinkingDetail(text: content),
            ),
    );
  }

  static String? _preview(String text) {
    if (text.isEmpty) return null;
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }
}

class _ThinkingDetail extends StatelessWidget {
  const _ThinkingDetail({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      key: const ValueKey('thinking-detail'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.reasoning,
                style: context.typo.sansBody.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: colors.muted,
                ),
              ),
            ),
            BayaCopyButton(key: const ValueKey('thinking-copy'), text: text),
          ],
        ),
        const SizedBox(height: 2),
        BayaGlassSurface(
          key: const ValueKey('thinking-content-surface'),
          role: BayaGlassRole.content,
          radius: 13,
          elevated: false,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                text,
                key: const ValueKey('thinking-detail-text'),
                style: context.typo.sansBody.copyWith(
                  fontSize: 13,
                  height: 1.5,
                  color: colors.text,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
