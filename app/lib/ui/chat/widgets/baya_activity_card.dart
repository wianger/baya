import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shared collapsed row for agent activity such as tools and thinking.
class BayaActivityCard extends StatelessWidget {
  const BayaActivityCard({
    super.key,
    required this.leading,
    required this.title,
    required this.onTap,
    this.disclosureKey,
    this.preview,
    this.previewMonospace = true,
    this.titleColor,
    this.previewColor,
  });

  final Widget leading;
  final String title;
  final String? preview;
  final bool previewMonospace;
  final Color? titleColor;
  final Color? previewColor;
  final VoidCallback? onTap;
  final Key? disclosureKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaGlassSurface(
      role: BayaGlassRole.content,
      radius: 18,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: disclosureKey,
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 13),
            child: Row(
              children: [
                SizedBox.square(dimension: 19, child: Center(child: leading)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          color: titleColor ?? colors.muted2,
                          fontSize: 13,
                        ),
                      ),
                      if (preview case final line? when line.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (previewMonospace
                                      ? context.typo.monoSmall
                                      : context.typo.sansBody)
                                  .copyWith(
                                    fontSize: 11.5,
                                    color: previewColor ?? colors.muted,
                                  ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 8),
                  Icon(LucideIcons.chevronRight, size: 16, color: colors.muted),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps content-heavy activity sheets visually detached from the screen edge.
///
/// The card behaves like a floating note on phones and stops growing beyond a
/// readable width on tablets, while still respecting landscape safe areas.
class BayaFloatingActivitySurface extends StatelessWidget {
  const BayaFloatingActivitySurface({
    super.key,
    required this.child,
    this.surfaceKey,
  });

  final Widget child;
  final Key? surfaceKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SizedBox(
            width: double.infinity,
            child: BayaGlassSurface(
              key: surfaceKey,
              role: BayaGlassRole.overlay,
              radius: 30,
              elevated: false,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared detail sheet framing for one agent activity item.
Future<void> showBayaActivityDetailSheet(
  BuildContext context, {
  required String title,
  required Widget child,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .38),
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .82,
    ),
    builder: (sheetContext) => BayaFloatingActivitySurface(
      surfaceKey: const ValueKey('activity-detail-sheet'),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: sheetContext.colors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  SizedBox.square(
                    dimension: 40,
                    child: IconButton.filledTonal(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(LucideIcons.x, size: 19),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: sheetContext.typo.title.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 40),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [child],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
