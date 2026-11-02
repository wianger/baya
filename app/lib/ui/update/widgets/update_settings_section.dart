import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
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
      title: context.l10n.couldNotStartDownload,
      message: context.l10n.openGitHubReleasesInstead,
      secondaryLabel: context.l10n.gitHubReleases,
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
          title: context.l10n.checkForUpdates,
          message: context.l10n.appUpToDate,
        );
      case UpdateCheckFailed():
        await showBayaNotice(
          context,
          title: context.l10n.checkForUpdates,
          message: context.l10n.couldNotCheckGitHub,
        );
      case UpdateBannerVisible():
        // Show a modal here rather than letting the background UpdateBanner
        // (Home is still in the navigation stack) raise a duplicate.
        await showBayaNotice(
          context,
          title: context.l10n.updateAvailable,
          message: context.l10n.versionReady(
            (vm.state as UpdateBannerVisible).info.version,
            '${(vm.state as UpdateBannerVisible).info.buildNumber}',
          ),
          confirmLabel: context.l10n.downloadApk,
          secondaryLabel: context.l10n.later,
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
    return BayaSurface(
      radius: 24,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.appUpdates,
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
            BayaButton(
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
                    ? context.l10n.checkingGitHub
                    : context.l10n.checkForUpdates,
              ),
              prominent: false,
            ),
            if (state is UpdateBannerVisible) ...[
              const SizedBox(height: 12),
              Text(
                context.l10n.versionAvailable(
                  state.info.version,
                  '${state.info.buildNumber}',
                ),
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
              BayaButton(
                buttonKey: const Key('download-github-apk'),
                onPressed: () => _download(context),
                icon: const Icon(Icons.download, size: 18),
                label: Text(context.l10n.downloadApk),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.updateKeepsData,
                style: context.typo.sansBody.copyWith(
                  color: context.colors.muted,
                ),
              ),
            ],
            TextButton(
              onPressed: vm.openReleases,
              child: Text(context.l10n.gitHubReleases),
            ),
          ],
        ),
      ),
    );
  }
}
