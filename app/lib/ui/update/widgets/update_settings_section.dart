import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class UpdateSettingsSection extends StatelessWidget {
  const UpdateSettingsSection({super.key});

  Future<void> _download(BuildContext context) async {
    final opened = await context.read<UpdateBannerViewModel>().download();
    if (!context.mounted || opened) return;
    await showBayaNotice(
      context,
      title: 'Could not start the download',
      message: 'Open GitHub Releases instead.',
      secondaryLabel: 'GitHub Releases',
      onSecondary: () => context.read<UpdateBannerViewModel>().openReleases(),
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
        // Show a modal here rather than letting the background UpdateBanner
        // (Home is still in the navigation stack) raise a duplicate.
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

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<UpdateBannerViewModel>();
    final state = vm.state;
    return BayaGlassSurface(
      radius: 24,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'App updates',
              style: context.typo.sansBody.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$kAppName ${vm.currentVersion} (${vm.currentBuildNumber})',
              style: context.typo.monoSmall.copyWith(
                color: context.colors.muted,
              ),
            ),
            const SizedBox(height: 12),
            BayaGlassButton(
              buttonKey: const Key('check-github-updates'),
              onPressed: state is UpdateCheckInProgress
                  ? null
                  : () => _check(context),
              icon: state is UpdateCheckInProgress
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update, size: 18),
              label: Text(
                state is UpdateCheckInProgress
                    ? 'Checking GitHub…'
                    : 'Check for updates',
              ),
              prominent: false,
            ),
            if (state is UpdateBannerVisible) ...[
              const SizedBox(height: 12),
              Text(
                'Version ${state.info.version} (${state.info.buildNumber}) is available.',
              ),
              if (state.info.notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  state.info.notes,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 12),
              BayaGlassButton(
                buttonKey: const Key('download-github-apk'),
                onPressed: () => _download(context),
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Download APK'),
              ),
              const SizedBox(height: 8),
              Text(
                'Open the download to update this app. Your pairings and settings are kept.',
                style: context.typo.sansBody.copyWith(
                  color: context.colors.muted,
                ),
              ),
            ],
            TextButton(
              onPressed: vm.openReleases,
              child: const Text('GitHub Releases'),
            ),
          ],
        ),
      ),
    );
  }
}
