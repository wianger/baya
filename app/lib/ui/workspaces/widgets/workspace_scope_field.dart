import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Displays a device, workspace or agent scope without Material's floating
/// [InputDecorator] label. The label owns layout space inside the card, so a
/// rounded glass surface can never clip a value or its caption.
class WorkspaceScopeField extends StatelessWidget {
  const WorkspaceScopeField({
    super.key,
    required this.interactionKey,
    required this.label,
    required this.value,
    required this.leading,
    required this.enabled,
    required this.onTap,
    this.supporting,
    this.supportingSemantics,
  });

  final Key interactionKey;
  final String label;
  final String value;
  final Widget leading;
  final bool enabled;
  final VoidCallback? onTap;
  final Widget? supporting;
  final String? supportingSemantics;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final supportingLabel = supportingSemantics == null
        ? enabled
              ? ''
              : ', unavailable'
        : ', $supportingSemantics';
    return Semantics(
      button: true,
      enabled: enabled,
      label: '$label, $value$supportingLabel',
      // A drawer row, as DeepSeek lists things: no card, an icon, the
      // choice, what it is in grey, and a chevron.
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: interactionKey,
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  IconTheme.merge(
                    data: IconThemeData(
                      color: enabled ? colors.text : colors.muted,
                      size: 20,
                    ),
                    child: leading,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 16,
                            height: 24 / 16,
                            fontWeight: FontWeight.w500,
                            color: enabled ? colors.text : colors.muted,
                          ),
                        ),
                        ?supporting,
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    maxLines: 1,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 13,
                      color: colors.muted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(LucideIcons.chevronDown, size: 16, color: colors.muted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
