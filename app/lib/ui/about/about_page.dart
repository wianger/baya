import 'package:app/data/diagnostics/crash_log.dart';
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
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Identity, version and the update button, then the project as grouped
/// rows like Settings. Settings keeps only configuration.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static final _project = Uri.parse('https://github.com/wianger/baya');
  static final _releases = Uri.parse(
    'https://github.com/wianger/baya/releases',
  );
  static final _homepage = Uri.parse('https://github.com/wianger');
  static final _issues = Uri.parse(
    'https://github.com/wianger/baya/issues/new',
  );

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
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        flexibleSpace: const BayaSurface(
          role: BayaSurfaceRole.navigation,
          radius: 0,
          elevated: false,
          child: SizedBox.expand(),
        ),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(LucideIcons.chevronLeft, size: 20, color: colors.text),
          tooltip: context.l10n.back,
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: Text(context.l10n.about),
      ),
      body: BayaBackdrop(
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
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.aboutTagline,
                      textAlign: TextAlign.center,
                      style: context.typo.sansBody.copyWith(
                        color: colors.muted2,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 12),
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
                    const _Problems(),
                    BayaSectionLabel(context.l10n.project, top: 24),
                    BayaGroup(
                      children: [
                        BayaRow(
                          icon: LucideIcons.code,
                          label: 'github.com/wianger/baya',
                          subtitle: context.l10n.sourceAndDocs,
                          chevron: true,
                          onTap: () => _open(context, _project),
                        ),
                        BayaRow(
                          icon: LucideIcons.scrollText,
                          label: context.l10n.releaseNotes,
                          chevron: true,
                          onTap: () => _open(context, _releases),
                        ),
                        BayaRow(
                          icon: LucideIcons.messageSquareWarning,
                          label: context.l10n.reportProblem,
                          chevron: true,
                          onTap: () => _open(context, _issues),
                        ),
                        BayaRow(
                          key: const Key('about-licenses'),
                          icon: LucideIcons.scale,
                          label: context.l10n.openSourceLicenses,
                          chevron: true,
                          onTap: () => showLicensePage(
                            context: context,
                            applicationName: kAppName,
                            applicationVersion: vm.currentVersion,
                          ),
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
    );
  }
}

class _Problems extends StatelessWidget {
  const _Problems();

  @override
  Widget build(BuildContext context) {
    final log = CrashLog.instance;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        final latest = log.reports.firstOrNull;
        if (latest == null) return const SizedBox.shrink();
        final l10n = context.l10n;
        return Padding(
          key: const Key('about-problems'),
          padding: const EdgeInsets.only(top: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BayaSectionLabel(l10n.problems(log.reports.length)),
              BayaGroup(
                children: [
                  BayaRow(
                    icon: LucideIcons.bug,
                    label: latest.error.split('\n').first,
                    subtitle: latest.time.toLocal().toString().substring(0, 16),
                  ),
                  BayaRow(
                    key: const Key('problem-copy'),
                    icon: LucideIcons.copy,
                    label: l10n.copyReport,
                    onTap: () =>
                        Clipboard.setData(ClipboardData(text: latest.text)),
                  ),
                  BayaRow(
                    key: const Key('problem-report'),
                    icon: LucideIcons.externalLink,
                    label: l10n.reportOnGitHub,
                    subtitle: l10n.reportOnGitHubHint,
                    chevron: true,
                    onTap: () => launchUrl(
                      crashIssueUrl(latest),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  BayaRow(
                    key: const Key('problem-clear'),
                    icon: LucideIcons.trash2,
                    label: l10n.clearProblems,
                    destructive: true,
                    onTap: log.clear,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
