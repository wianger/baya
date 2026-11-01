import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Onboarding step 1 — welcome. Static, no animations (per plan 14 D2 —
/// "Welcome conservador (sem animações)").
class WelcomeStep extends StatelessWidget {
  final VoidCallback onNext;
  const WelcomeStep({super.key, required this.onNext});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaReveal(
      offset: 12,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: AppMark(size: 104, tile: true)),
                const SizedBox(height: 24),
                Text(
                  kAppName,
                  textAlign: TextAlign.center,
                  style: brandDisplayTextStyle(
                    fontSize: 48,
                    color: colors.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your agents. Across devices.',
                  textAlign: TextAlign.center,
                  style: context.typo.sansBody.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: colors.muted2,
                  ),
                ),
                const SizedBox(height: 28),
                BayaGlassSurface(
                  radius: 26,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    child: Column(
                      children: [
                        const _FeatureRow(
                          icon: LucideIcons.scanQrCode,
                          title: 'Pair securely',
                          subtitle: 'Connect your own computers in seconds.',
                        ),
                        const SizedBox(height: 15),
                        const _FeatureRow(
                          icon: LucideIcons.layoutDashboard,
                          title: 'Keep your workspaces',
                          subtitle:
                              'Move between projects without losing context.',
                        ),
                        const SizedBox(height: 15),
                        const _FeatureRow(
                          icon: LucideIcons.messageSquareText,
                          title: 'Continue anywhere',
                          subtitle: 'Pick up active sessions from your phone.',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                BayaGlassButton(
                  onPressed: onNext,
                  label: const Text('Get started'),
                  minimumSize: const Size.fromHeight(52),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colors.selection,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, size: 19, color: colors.accent),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: context.typo.sansBody.copyWith(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: context.typo.sansBody.copyWith(
                  fontSize: 12.5,
                  height: 1.35,
                  color: colors.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
