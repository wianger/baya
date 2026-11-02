import 'package:app/domain/entities/update_info.dart';

/// State of the in-app update notice, plus the manual check's progress.
sealed class UpdateBannerState {
  const UpdateBannerState();
}

/// Nothing to show. `const`, so `emit` dedupes by identity.
final class UpdateBannerHidden extends UpdateBannerState {
  const UpdateBannerHidden();
}

/// A newer, undismissed version is available.
final class UpdateBannerVisible extends UpdateBannerState {
  const UpdateBannerVisible(this.info);

  final UpdateInfo info;

  // Equal by version: re-emitting the same manifest does not rebuild.
  @override
  bool operator ==(Object other) =>
      other is UpdateBannerVisible && other.info.version == info.version;

  @override
  int get hashCode => info.version.hashCode;
}

final class UpdateCheckInProgress extends UpdateBannerState {
  const UpdateCheckInProgress();
}

final class UpdateCheckCurrent extends UpdateBannerState {
  const UpdateCheckCurrent();
}

final class UpdateCheckFailed extends UpdateBannerState {
  const UpdateCheckFailed(this.message);
  final String message;
}
