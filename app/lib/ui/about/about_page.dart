import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_group.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Identity, version and the update button, then the project as grouped
/// rows like Settings. Settings keeps only configuration.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static final _project = Uri.parse('https://github.com/wianger/baya');
  static final _releases = Uri.parse(
    'https://github.com/wianger/baya/releases',
  );
  static final _homepage = Uri.parse('https://github.com/wianger');

  Future<void> _open(BuildContext context, Uri uri) async {
    final opened = await context.read<UpdateBannerViewModel>().openUrl(
      uri.toString(),
    );
    if (!context.mounted || opened) return;
    await showBayaNotice(
      context,
      title: context.l10n.couldNotOpenLink,
      message: context.l10n.checkConnectionTryAgain,
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
        // Show the modal here and silence the background UpdateBanner
        // (Home stays mounted below About in the navigation stack). The
        // ViewModel's `_showing` gate only prevents a duplicate from the
        // same widget; we own the About route's prompt directly.
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

  Future<void> _download(BuildContext context) async {
    final opened = await context.read<UpdateBannerViewModel>().download();
    if (!context.mounted || opened) return;
    await showBayaNotice(
      context,
      title: context.l10n.couldNotStartDownload,
      message: context.l10n.openGitHubReleasesInstead,
      secondaryLabel: context.l10n.gitHubReleases,
      onSecondary: () => _open(context, _releases),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.watch<UpdateBannerViewModel>();
    final updateState = vm.state;
    return BayaTintedPage(
      child: Scaffold(
        backgroundColor: BayaTintedPage.ground(context),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          toolbarHeight: 72,
          automaticallyImplyLeading: false,
          leadingWidth: 84,
          titleSpacing: 0,
          leading: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Center(
              child: BayaSurface(
                role: BayaSurfaceRole.floating,
                radius: 26,
                child: SizedBox.square(
                  dimension: 52,
                  child: IconButton(
                    icon: Icon(
                      LucideIcons.arrowLeft,
                      size: 22,
                      color: colors.text,
                    ),
                    tooltip: context.l10n.back,
                    onPressed: () =>
                        context.canPop() ? context.pop() : context.go('/home'),
                  ),
                ),
              ),
            ),
          ),
          title: Text(context.l10n.about),
        ),
        body: BayaBackdrop(
          translucent: true,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: BayaReveal(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
                    children: [
                      const Center(child: AppMark(size: 96, tile: true)),
                      const SizedBox(height: 14),
                      Text(
                        kAppName,
                        textAlign: TextAlign.center,
                        style: brandDisplayTextStyle(
                          fontSize: 44,
                          color: colors.text,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // The version and the licence as two chips, the
                      // licence opening the open-source notices.
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _Chip(text: 'v${vm.currentVersion}', filled: true),
                          const SizedBox(width: 10),
                          _Chip(
                            key: const Key('about-licenses'),
                            text: 'GPL-3.0',
                            onTap: () => showLicensePage(
                              context: context,
                              applicationName: kAppName,
                              applicationVersion: vm.currentVersion,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        context.l10n.aboutTagline,
                        textAlign: TextAlign.center,
                        style: context.typo.sansBody.copyWith(
                          color: colors.muted2,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Center(
                        child: BayaButton(
                          buttonKey: const Key('check-github-updates'),
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
                          label: Text(
                            updateState is UpdateCheckInProgress
                                ? context.l10n.checkingGitHub
                                : context.l10n.checkForUpdates,
                          ),
                          prominent: false,
                        ),
                      ),
                      if (updateState is UpdateBannerVisible) ...[
                        const SizedBox(height: 16),
                        BayaSurface(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.versionReady(
                                    updateState.info.version,
                                    '${updateState.info.buildNumber}',
                                  ),
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
                                BayaButton(
                                  buttonKey: const Key('download-github-apk'),
                                  onPressed: () => _download(context),
                                  icon: const Icon(
                                    LucideIcons.download,
                                    size: 18,
                                  ),
                                  label: Text(context.l10n.downloadApk),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  context.l10n.updateKeepsDataAndroid,
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
                      BayaSectionLabel(context.l10n.more, top: 24),
                      BayaGroup(
                        children: [
                          BayaRow(
                            icon: LucideIcons.code,
                            label: context.l10n.project,
                            subtitle: 'github.com/wianger/baya',
                            trailing: Icon(
                              LucideIcons.squareArrowOutUpRight,
                              size: 20,
                              color: colors.text,
                            ),
                            onTap: () => _open(context, _project),
                          ),
                        ],
                      ),
                      BayaSectionLabel(context.l10n.builtBy, top: 24),
                      BayaGroup(
                        children: [
                          BayaRow(
                            icon: LucideIcons.user,
                            label: 'wianger',
                            subtitle: 'github.com/wianger',
                            chevron: true,
                            onTap: () => _open(context, _homepage),
                          ),
                        ],
                      ),
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

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.text, this.filled = false, this.onTap});

  final String text;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: filled ? colors.accent : colors.bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Text(
            text,
            style: context.typo.sansBody.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: filled ? colors.onAccent : colors.text,
            ),
          ),
        ),
      ),
    );
  }
}
