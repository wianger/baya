import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A small-caps label over a group.
class BayaSectionLabel extends StatelessWidget {
  const BayaSectionLabel(this.label, {super.key, this.top = 0});

  final String label;

  /// Space above, when the label follows other content.
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(4, top, 4, 8),
    child: Text(
      label.toUpperCase(),
      style: context.typo.sansBody.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.3,
        color: context.colors.muted,
      ),
    ),
  );
}

/// Rows grouped on one card with hairline dividers: settings, choices,
/// session lists, in sheets and on pages alike.
class BayaGroup extends StatelessWidget {
  const BayaGroup({super.key, required this.children, this.danger = false});

  final List<Widget> children;

  /// Tints the card for a destructive confirmation.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: danger ? colors.error.withValues(alpha: .08) : colors.inputFill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: danger ? colors.error.withValues(alpha: .35) : colors.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 50, color: colors.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One row in a [BayaGroup]: an action, or a choice marked when picked.
class BayaRow extends StatelessWidget {
  const BayaRow({
    super.key,
    required this.label,
    this.icon,
    this.subtitle,
    this.value,
    this.trailing,
    this.selected = false,
    this.highlighted = false,
    this.destructive = false,
    this.chevron = false,
    this.monospaceSubtitle = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final String? subtitle;

  /// The current setting, right-aligned before the chevron.
  final String? value;
  final Widget? trailing;
  final bool selected;

  /// The row is the one open now: tinted rather than checked.
  final bool highlighted;
  final bool destructive;
  final bool chevron;
  final bool monospaceSubtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tint = destructive ? colors.error : colors.text;
    return InkWell(
      onTap: onTap,
      child: Ink(
        color: highlighted ? colors.selection : null,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 13, trailing == null ? 16 : 6, 13),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 18,
                  color: destructive
                      ? tint
                      : selected
                      ? colors.accent
                      : colors.muted2,
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.sansBody.copyWith(
                        fontSize: 15,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: onTap == null && !selected ? colors.muted : tint,
                      ),
                    ),
                    if (subtitle case final text? when text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (monospaceSubtitle
                                      ? context.typo.monoSmall
                                      : context.typo.sansBody)
                                  .copyWith(fontSize: 12, color: colors.muted),
                        ),
                      ),
                  ],
                ),
              ),
              if (value case final text?)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: context.typo.sansBody.copyWith(
                        fontSize: 14,
                        color: colors.muted,
                      ),
                    ),
                  ),
                ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    LucideIcons.check,
                    size: 17,
                    color: colors.accent,
                  ),
                ),
              ?trailing,
              if (chevron)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    LucideIcons.chevronRight,
                    size: 16,
                    color: colors.muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
