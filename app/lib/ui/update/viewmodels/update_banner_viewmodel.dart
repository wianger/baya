import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/domain/value_objects/semver.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/update/states/update_banner_state.dart';

/// In-app update notice (Android only). [check] runs at startup, reads the
/// release manifest, and emits [UpdateBannerVisible] when a newer version
/// exists that the user has not dismissed. Best-effort: failures are silent.
///
/// The platform gate is the injected [enabled] flag, so the rule stays
/// testable on any machine that runs `flutter test`.
class UpdateBannerViewModel extends ViewModel<UpdateBannerState> {
  UpdateBannerViewModel(
    this._checker,
    this._dismissed,
    this._opener, {
    required this.currentVersion,
    required this.enabled,
    this.currentBuildNumber = 0,
    this.platform = 'android',
    this.format = 'apk',
    this.arch = 'universal',
    this.fallbackUrl = _kFallbackUrl,
  }) : super(const UpdateBannerHidden());

  final UpdateChecker _checker;
  final DismissedUpdateStore _dismissed;
  final UrlOpener _opener;

  /// Running app version (from `package_info`).
  final String currentVersion;
  final int currentBuildNumber;

  /// Platform gate, injected so tests run anywhere.
  final bool enabled;

  /// Which artifact to download.
  final String platform;
  final String format;
  final String arch;

  /// Fallback when the manifest has no matching artifact.
  final String fallbackUrl;

  static const String _kFallbackUrl =
      'https://github.com/wianger/baya/releases';

  bool _checked = false;
  bool _disposed = false;

  /// Checks once per instance whether to show the notice. Silent on failure.
  Future<void> check() async {
    if (!enabled) return;
    if (_checked) return;
    _checked = true;

    final latest = await _checker.fetchLatest();
    if (_disposed) return;
    if (latest == null) return;
    if (!_isNewer(latest)) return;

    final dismissed = await _dismissed.dismissedVersion();
    if (_disposed) return;
    if (dismissed == latest.version) return;

    emit(UpdateBannerVisible(latest));
  }

  bool _isNewer(UpdateInfo info) {
    if (info.buildNumber > 0 && currentBuildNumber > 0) {
      return info.buildNumber > currentBuildNumber &&
          compareSemver(info.version, currentVersion) >= 0;
    }
    return isNewerVersion(info.version, currentVersion);
  }

  /// Manual checks bypass dismissal and report network/API failures visibly.
  Future<void> checkManually() async {
    if (!enabled || state is UpdateCheckInProgress) return;
    emit(const UpdateCheckInProgress());
    final latest = await _checker.fetchLatest();
    if (_disposed) return;
    if (latest == null) {
      emit(
        const UpdateCheckFailed(
          'Could not check GitHub. Check your connection and try again.',
        ),
      );
    } else if (_isNewer(latest)) {
      emit(UpdateBannerVisible(latest));
    } else {
      emit(const UpdateCheckCurrent());
    }
  }

  Future<bool> openReleases() => _opener.open(fallbackUrl);

  /// Open an arbitrary external link through the same platform opener the
  /// update flow uses, so About/markdown links share one error path.
  Future<bool> openUrl(String url) => _opener.open(url);

  /// Hides the notice until a newer version ships.
  Future<void> dismiss() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    final version = current.info.version;
    emit(const UpdateBannerHidden());
    await _dismissed.dismiss(version);
  }

  /// Opens the APK download, or the releases page without a matching artifact.
  Future<bool> download() async {
    final current = state;
    if (current is! UpdateBannerVisible) return false;
    final artifact = current.info.artifactFor(
      platform: platform,
      format: format,
      arch: arch,
    );
    return _opener.open(artifact?.url ?? fallbackUrl);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
