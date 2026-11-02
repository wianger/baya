/// Opens an external URL (browser or OS download).
abstract class UrlOpener {
  /// Opens [url]; `true` on success.
  Future<bool> open(String url);
}
