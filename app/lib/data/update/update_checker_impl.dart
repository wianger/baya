import 'dart:convert';

import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/domain/value_objects/semver.dart';
import 'package:http/http.dart' as http;

/// Only this fork's signed Android development release channel is installable.
class UpdateCheckerImpl implements UpdateChecker {
  UpdateCheckerImpl({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  static const releasesUrl = 'https://github.com/wianger/baya/releases';
  static const apiUrl =
      'https://api.github.com/repos/wianger/baya/releases?per_page=100';
  static const apkName = 'Baya-Android.apk';
  final http.Client _client;
  final Duration timeout;

  @override
  Future<UpdateInfo?> fetchLatest() async {
    try {
      final response = await _client
          .get(
            Uri.parse(apiUrl),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseReleases(jsonDecode(response.body));
    } on FormatException {
      return null;
    } catch (_) {
      return null; // offline, timeout, TLS: best-effort by contract
    }
  }

  static bool _isOwnAssetUrl(Object? raw, String tag) {
    if (raw is! String) return false;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port != 443) {
      return false;
    }
    return uri.pathSegments.join('/') ==
        'wianger/baya/releases/download/$tag/$apkName';
  }

  /// Prereleases are intentional on this channel; tags/assets are the filter.
  static UpdateInfo? parseReleases(Object? json) {
    if (json is! List) return null;
    final candidates = <UpdateInfo>[];
    for (final release in json) {
      if (release is! Map || release['draft'] != false) continue;
      final tag = release['tag_name'];
      if (tag is! String) continue;
      final match = RegExp(r'^android-dev-v(\d+\.\d+\.\d+)\+(\d+)$')
          .firstMatch(tag);
      if (match == null) continue;
      final build = int.tryParse(match.group(2)!);
      final assets = release['assets'];
      if (build == null || build <= 0 || assets is! List) continue;
      final expectedUrl = '$releasesUrl/download/$tag/$apkName';
      for (final asset in assets) {
        if (asset is! Map ||
            asset['name'] != apkName ||
            !_isOwnAssetUrl(asset['browser_download_url'], tag) ||
            asset['state'] != 'uploaded' ||
            asset['size'] is! num ||
            (asset['size'] as num) <= 0) {
          continue;
        }
        final digest = asset['digest'];
        candidates.add(
          UpdateInfo(
            version: match.group(1)!,
            buildNumber: build,
            date: release['published_at'] is String
                ? release['published_at'] as String
                : '',
            notes: release['body'] is String ? release['body'] as String : '',
            releaseUrl: '$releasesUrl/tag/$tag',
            artifacts: [
              UpdateArtifact(
                platform: 'android',
                arch: 'arm64',
                format: 'apk',
                url: expectedUrl,
                sha256: digest is String && digest.startsWith('sha256:')
                    ? digest.substring(7)
                    : '',
                size: (asset['size'] as num).toInt(),
              ),
            ],
          ),
        );
        break;
      }
    }
    candidates.sort((a, b) {
      final version = compareSemver(b.version, a.version);
      return version != 0 ? version : b.buildNumber.compareTo(a.buildNumber);
    });
    return candidates.firstOrNull;
  }
}
