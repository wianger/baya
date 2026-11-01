import 'package:app/ui/core/branding/app_brand.dart';
import 'dart:io' show Platform;

import 'package:app/config/dependencies.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Plan 23 — first-launch gate when the platform's key-sync surface
/// (iCloud Keychain on iOS, Google Backup / Block Store on Android) is
/// not available. The app cannot proceed without it because the Owner
/// Ed25519 keypair has no other persistence path.
class SyncRequiredPage extends StatefulWidget {
  const SyncRequiredPage({super.key});

  @override
  State<SyncRequiredPage> createState() => _SyncRequiredPageState();
}

class _SyncRequiredPageState extends State<SyncRequiredPage> {
  bool _checking = false;

  Future<void> _recheck() async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await injector.get<OwnerIdentityBridge>().boot();
    if (!mounted) return;
    setState(() => _checking = false);
    if (result is! SyncUnavailableResult) {
      // Bounce through /boot so the router's redirect logic re-evaluates
      // (pairs-empty → /onboarding, pairs-non-empty → /home).
      context.go('/boot');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = Platform.isIOS;
    final requirements = isIOS ? _iosRequirements : _androidRequirements;
    final why = isIOS
        ? '$kAppName keeps your Ed25519 owner key in iCloud Keychain so '
              'you can switch iPhones or pair your iPad without scanning '
              'a new QR.'
        : '$kAppName keeps your Ed25519 owner key in Google Block Store '
              'so you can restore it on a new device through Google '
              'Backup without losing your paired Pis.';

    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: BayaBackdrop(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: BayaReveal(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: BayaGlassSurface(
                          role: BayaGlassRole.control,
                          radius: 19,
                          elevated: false,
                          child: SizedBox.square(
                            dimension: 58,
                            child: Icon(
                              isIOS
                                  ? LucideIcons.cloudOff
                                  : LucideIcons.cloudUpload,
                              color: colors.accent,
                              size: 27,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Sync required',
                        style: context.typo.sansBody.copyWith(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: colors.text,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        why,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 13.5,
                          color: colors.muted2,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'TO ENABLE ON THIS DEVICE',
                        style: context.typo.sansBody.copyWith(
                          fontSize: 11,
                          color: colors.muted,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.65,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: ListView.separated(
                          itemCount: requirements.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 9),
                          itemBuilder: (_, i) => _RequirementCard(
                            index: i + 1,
                            requirement: requirements[i],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _checking ? null : _recheck,
                        style: FilledButton.styleFrom(
                          disabledBackgroundColor: colors.border,
                          minimumSize: const Size.fromHeight(50),
                        ),
                        child: _checking
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  color: colors.onAccent,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Check again'),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Requirement {
  final String title;
  final String path;
  final String? note;
  const _Requirement({required this.title, required this.path, this.note});
}

const _androidRequirements = <_Requirement>[
  _Requirement(
    title: 'Set up a screen lock',
    path: 'Settings › Security › Screen lock',
    note: 'PIN, pattern or biometrics — required by Block Store.',
  ),
  _Requirement(
    title: 'Turn on Google Backup',
    path:
        'Settings › System › Backup\n'
        '(Samsung: Settings › Accounts and backup › Backup data)',
  ),
  _Requirement(
    title: 'Sign in to a Google account',
    path: 'Settings › Passwords & accounts › Add account › Google',
  ),
];

const _iosRequirements = <_Requirement>[
  _Requirement(
    title: 'Sign in to iCloud',
    path: 'Settings › [your name]',
    note: 'If you see "Sign in to your iPhone" at the top, tap it.',
  ),
  _Requirement(
    title: 'Turn on iCloud Keychain',
    path: 'Settings › [your name] › iCloud › Passwords and Keychain',
    note: 'Toggle "Sync this iPhone" on.',
  ),
];

class _RequirementCard extends StatelessWidget {
  final int index;
  final _Requirement requirement;
  const _RequirementCard({required this.index, required this.requirement});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaGlassSurface(
      radius: 20,
      elevated: false,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BayaGlassSurface(
              role: BayaGlassRole.control,
              radius: 9,
              elevated: false,
              child: SizedBox.square(
                dimension: 28,
                child: Center(
                  child: Text(
                    '$index',
                    style: context.typo.sansBody.copyWith(
                      fontSize: 11,
                      color: colors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    requirement.title,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 14,
                      color: colors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    requirement.path,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 12,
                      color: colors.muted2,
                      height: 1.45,
                    ),
                  ),
                  if (requirement.note != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      requirement.note!,
                      style: context.typo.sansBody.copyWith(
                        fontSize: 11.5,
                        color: colors.muted,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
