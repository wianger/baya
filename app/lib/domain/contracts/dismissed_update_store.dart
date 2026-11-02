/// Remembers which update the user dismissed. The notice stays hidden for
/// that version and returns when a newer one ships.
abstract class DismissedUpdateStore {
  /// The last dismissed version, or `null`.
  Future<String?> dismissedVersion();

  /// Marks [version] as dismissed.
  Future<void> dismiss(String version);
}
