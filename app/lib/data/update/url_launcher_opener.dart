import 'package:app/domain/contracts/url_opener.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens external URLs with `url_launcher` (used to download the update APK).
/// Returns `false` for an invalid URL or a missing handler.
class UrlLauncherOpener implements UrlOpener {
  const UrlLauncherOpener();

  @override
  Future<bool> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
