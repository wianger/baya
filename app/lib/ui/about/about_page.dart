import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// About follows the same hierarchy as FlClash: identity, version, update
/// action, then project resources. Settings keeps only configuration.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static final _project = Uri.parse('https://github.com/wianger/baya');
  static final _releases = Uri.parse(
    'https://github.com/wianger/baya/releases',
  );
  static final _homepage = Uri.parse('https://github.com/wianger');
  static final _avatarUrl = Uri.parse(
    'https://github.com/wianger.png?size=160',
  );

  Future<void> _open(BuildContext context, Uri uri) async {
    final opened = await context.read<UpdateBannerViewModel>().openUrl(
      uri.toString(),
    );
    if (!context.mounted || opened) return;
    await showBayaNotice(
      context,
      title: 'Could not open the link',
      message: 'Check your connection and try again.',
    );
  }

  Future<void> _check(BuildContext context) async {
    final vm = context.read<UpdateBannerViewModel>();
    await vm.checkManually();
    if (!context.mounted) return;
    switch (vm.state) {
      case UpdateCheckCurrent():
        await showBayaNotice(
          context,
          title: 'Check for updates',
          message: 'The app is already up to date.',
        );
      case UpdateCheckFailed():
        await showBayaNotice(
          context,
          title: 'Check for updates',
          message: 'Could not check GitHub. Check your connection.',
        );
      case UpdateBannerVisible():
        // Show the modal here and silence the background UpdateBanner
        // (Home stays mounted below About in the navigation stack). The
        // ViewModel's `_showing` gate only prevents a duplicate from the
        // same widget; we own the About route's prompt directly.
        await showBayaNotice(
          context,
          title: 'Update available',
          message:
              'Version ${(vm.state as UpdateBannerVisible).info.version} '
              '(${(vm.state as UpdateBannerVisible).info.buildNumber}) is ready to download.',
          confirmLabel: 'Download APK',
          secondaryLabel: 'Later',
          onConfirm: () => _download(context),
          onSecondary: vm.dismiss,
          dismissible: false,
        );
      default:
        break;
    }
  }

  Future<void> _download(BuildContext context) async {
    final opened = await context.read<UpdateBannerViewModel>().download();
    if (!context.mounted || opened) return;
    await showBayaNotice(
      context,
      title: 'Could not start the download',
      message: 'Open GitHub Releases instead.',
      secondaryLabel: 'GitHub Releases',
      onSecondary: () => _open(context, _releases),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.watch<UpdateBannerViewModel>();
    final updateState = vm.state;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        flexibleSpace: const BayaGlassSurface(
          role: BayaGlassRole.navigation,
          radius: 0,
          elevated: false,
          child: SizedBox.expand(),
        ),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(LucideIcons.chevronLeft, size: 20, color: colors.text),
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('About'),
      ),
      body: BayaBackdrop(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: BayaReveal(
                offset: 8,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
                  children: [
                    const Center(child: AppMark(size: 104, tile: true)),
                    const SizedBox(height: 18),
                    Text(
                      kAppName,
                      textAlign: TextAlign.center,
                      style: context.typo.title.copyWith(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.selection,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          child: Text(
                            'v${vm.currentVersion} (${vm.currentBuildNumber})',
                            style: context.typo.monoSmall.copyWith(
                              color: colors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'A focused remote client for coding-agent sessions on your '
                      'own computers.',
                      textAlign: TextAlign.center,
                      style: context.typo.sansBody.copyWith(
                        color: colors.muted,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Center(
                      child: FilledButton.tonalIcon(
                        key: const Key('check-github-updates'),
                        onPressed: updateState is UpdateCheckInProgress
                            ? null
                            : () => _check(context),
                        icon: updateState is UpdateCheckInProgress
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(LucideIcons.refreshCw, size: 18),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            updateState is UpdateCheckInProgress
                                ? 'Checking GitHub…'
                                : 'Check for updates',
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                        ),
                      ),
                    ),
                    if (updateState is UpdateBannerVisible) ...[
                      const SizedBox(height: 16),
                      BayaGlassSurface(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Version ${updateState.info.version} '
                                '(${updateState.info.buildNumber}) is available.',
                                style: context.typo.sansBody.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (updateState.info.notes.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  updateState.info.notes,
                                  maxLines: 12,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.typo.sansBody.copyWith(
                                    color: colors.muted,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                key: const Key('download-github-apk'),
                                onPressed: () => _download(context),
                                icon: const Icon(
                                  LucideIcons.download,
                                  size: 18,
                                ),
                                label: const Text('Download APK'),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Your pairings and settings are kept when Android '
                                'installs the update.',
                                style: context.typo.sansBody.copyWith(
                                  color: colors.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 8),
                      child: Text(
                        'More',
                        style: context.typo.sansBody.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    BayaGlassSurface(
                      child: Column(
                        children: [
                          _LinkTile(
                            icon: LucideIcons.code,
                            title: 'Project',
                            subtitle: 'github.com/wianger/baya',
                            onTap: () => _open(context, _project),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 8),
                      child: Text(
                        'Built by',
                        style: context.typo.sansBody.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    BayaGlassSurface(
                      child: _LinkTile(
                        icon: LucideIcons.user,
                        imageUrl: _avatarUrl.toString(),
                        title: 'wianger',
                        subtitle: 'github.com/wianger',
                        onTap: () => _open(context, _homepage),
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

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.imageUrl,
  });

  final IconData icon;
  final String? imageUrl;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListTile(
      leading: imageUrl == null
          ? Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: colors.selection,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, size: 19, color: colors.text),
            )
          : Container(
              width: 40,
              height: 40,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: colors.border),
              ),
              child: ClipOval(
                child: Image.network(
                  imageUrl!,
                  key: const Key('built-by-github-avatar'),
                  semanticLabel: 'GitHub avatar for wianger',
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return Icon(
                      LucideIcons.user,
                      size: 18,
                      color: colors.muted,
                    );
                  },
                  errorBuilder: (_, _, _) =>
                      Icon(LucideIcons.user, size: 18, color: colors.muted),
                ),
              ),
            ),
      title: Text(title),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.typo.monoSmall.copyWith(color: colors.muted),
      ),
      trailing: Icon(LucideIcons.arrowUpRight, size: 17, color: colors.muted),
      onTap: onTap,
    );
  }
}
