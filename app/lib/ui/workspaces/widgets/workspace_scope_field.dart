import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
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
      child: BayaSurface(
        radius: 18,
        elevated: false,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: interactionKey,
            onTap: enabled ? onTap : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 11, 13, 11),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 38,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: enabled
                              ? colors.selection
                              : colors.inputFill.withValues(alpha: .62),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(child: leading),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 11,
                              height: 1.15,
                              fontWeight: FontWeight.w600,
                              letterSpacing: .15,
                              color: colors.muted,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 15,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              color: enabled ? colors.text : colors.muted,
                            ),
                          ),
                          if (supporting case final widget?) ...[
                            const SizedBox(height: 3),
                            widget,
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(
                      LucideIcons.chevronDown,
                      size: 18,
                      color: enabled ? colors.muted2 : colors.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
