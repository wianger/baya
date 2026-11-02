import 'dart:io';
import 'dart:convert';

import 'package:app/data/update/update_checker_impl.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> release(
  String version,
  int build, {
  bool draft = false,
  bool foreign = false,
}) {
  final tag = 'android-dev-v$version+$build';
  return {
    'draft': draft,
    'prerelease': true,
    'tag_name': tag,
    'body': 'Release notes',
    'published_at': '2026-10-30T10:00:00Z',
    'assets': [
      {
        'name': UpdateCheckerImpl.apkName,
        'state': 'uploaded',
        'size': 123,
        'browser_download_url': foreign
            ? 'https://example.com/foreign.apk'
            : '${UpdateCheckerImpl.releasesUrl}/download/$tag/${UpdateCheckerImpl.apkName}',
        'digest': 'sha256:abc',
      },
    ],
  };
}

void main() {
  test('selects newest personal release regardless of GitHub list order', () {
    final info = UpdateCheckerImpl.parseReleases([
      release('1.2.1', 9),
      release('1.2.1', 11),
      release('1.2.0', 8),
    ])!;
    expect(info.buildNumber, 11);
    expect(info.version, '1.2.1');
    expect(info.notes, 'Release notes');
    expect(info.artifacts.single.sha256, 'abc');
    expect(info.releaseUrl, endsWith('/tag/android-dev-v1.2.1+11'));
  });
  test('ignores drafts, upstream tags, foreign URLs and missing APKs', () {
    expect(
      UpdateCheckerImpl.parseReleases([
        release('9.0.0', 100, draft: true),
        release('9.0.0', 100, foreign: true),
        {...release('9.0.0', 100), 'tag_name': 'app-v9.0.0'},
        {...release('9.0.0', 100), 'assets': <Object>[]},
        null,
        'bad json shape',
      ]),
      isNull,
    );
  });
  test(
    'HTTP client uses GitHub releases API and handles status/JSON failures',
    () async {
      var status = 200;
      var body = jsonEncode([release('1.2.1', 9)]);
      final checker = UpdateCheckerImpl(
        client: MockClient((request) async {
          expect(request.url.toString(), UpdateCheckerImpl.apiUrl);
          return http.Response(body, status);
        }),
      );
      expect((await checker.fetchLatest())!.buildNumber, 9);
      status = 403;
      body = 'rate limit';
      expect(await checker.fetchLatest(), isNull);
      status = 200;
      body = '<html>';
      expect(await checker.fetchLatest(), isNull);
      final offline = UpdateCheckerImpl(
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      expect(await offline.fetchLatest(), isNull);
    },
  );
}
