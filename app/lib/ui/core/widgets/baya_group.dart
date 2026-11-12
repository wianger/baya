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
    this.spinning = false,
    this.onTap,
    this.onLongPress,
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

  /// The icon turns: work is under way (a loader glyph).
  final bool spinning;
  final VoidCallback? onTap;

  /// Holding the row: its actions, where it has some.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tint = destructive ? colors.error : colors.text;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Ink(
        color: highlighted ? colors.selection : null,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 13, trailing == null ? 16 : 6, 13),
          child: Row(
            children: [
              if (icon != null) ...[
                _Spin(
                  spinning: spinning,
                  child: Icon(
                    icon,
                    size: 18,
                    color: destructive
                        ? tint
                        : spinning
                        ? colors.working
                        : selected
                        ? colors.accent
                        : colors.muted2,
                  ),
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

/// Turns [child] once a second while [spinning]; still when the system asks
/// for less motion.
class _Spin extends StatefulWidget {
  const _Spin({required this.spinning, required this.child});

  final bool spinning;
  final Widget child;

  @override
  State<_Spin> createState() => _SpinState();
}

class _SpinState extends State<_Spin> with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Spin oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.spinning && !MediaQuery.disableAnimationsOf(context)) {
      if (!_turns.isAnimating) _turns.repeat();
    } else {
      _turns
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RotationTransition(turns: _turns, child: widget.child);
}
