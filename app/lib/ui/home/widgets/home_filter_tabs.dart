import 'package:app/routing/adaptive.dart' show kMaxContentWidth;
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Plan-38 Fase 3 — presence filter for the Home list. A 3-pill segmented
/// control (All · Online · Offline) the user taps to slice the existing
/// (peer → room) list by liveness. Pure view filter: tapping a tab never
/// reloads data, it only narrows [HomeViewModel.visibleItems]. The default
/// tab is Online (set by [HomeList.filter]).
class HomeFilterTabs extends StatelessWidget {
  final HomeFilter filter;

  /// Per-tab counts for the badges (each tab shows its own slice's size).
  final ({int all, int online, int offline}) counts;
  final ValueChanged<HomeFilter> onSelected;

  const HomeFilterTabs({
    super.key,
    required this.filter,
    required this.counts,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: BayaGlassSurface(
        role: BayaGlassRole.control,
        radius: 15,
        elevated: false,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              _segment(context, HomeFilter.all, 'All', counts.all),
              _segment(context, HomeFilter.online, 'Online', counts.online),
              _segment(context, HomeFilter.offline, 'Offline', counts.offline),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    HomeFilter value,
    String label,
    int count,
  ) {
    final colors = context.colors;
    final selected = filter == value;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelected(value),
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : BayaMotion.standard,
          curve: BayaMotion.enter,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? colors.inputFill : colors.bg.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border.all(
                    color: colors.border.withValues(alpha: 0.7),
                    width: 0.5,
                  )
                : null,
            boxShadow: selected && !MediaQuery.highContrastOf(context)
                ? [
                    BoxShadow(
                      color: colors.glassShadow.withValues(alpha: 0.52),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.05,
                    color: selected ? colors.text : colors.muted,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  fontFamily: kSansFamily,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: selected ? colors.text : colors.muted2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Plan-38 Fase 3 — empty state shown BELOW the tabs when the current tab
/// has no matching sessions but the list isn't globally empty (the
/// globally-empty case keeps the existing "Nothing here…" lonely state and
/// hides the tabs entirely). Copy varies per tab so the user understands
/// it's a filter, not a dead end. [HomeFilter.all] is included for
/// completeness but in practice never renders empty while items exist.
class HomeFilterEmptyState extends StatelessWidget {
  final HomeFilter filter;
  const HomeFilterEmptyState({super.key, required this.filter});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (String title, String subtitle) = switch (filter) {
      HomeFilter.online => (
        'No sessions online',
        'Live sessions appear here when a paired Pi is active.',
      ),
      HomeFilter.offline => (
        'No offline sessions',
        'Sessions you’ve seen before that aren’t live show up here.',
      ),
      HomeFilter.all => (
        'Nothing here…',
        'When a paired Pi opens a session, it shows up here.',
      ),
    };
    return BayaReveal(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: BayaGlassSurface(
              radius: 28,
              elevated: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 26, 26, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.inbox, color: colors.muted, size: 32),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      style: context.typo.sansBody.copyWith(
                        color: colors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: context.typo.sansBody.copyWith(
                        color: colors.muted,
                        fontSize: 13,
                        height: 1.45,
                      ),
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
