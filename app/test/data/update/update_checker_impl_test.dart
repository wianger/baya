import 'dart:convert';
import 'package:app/data/update/update_checker_impl.dart';
import 'package:dio/dio.dart';
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
    'HTTP adapter uses GitHub releases API and handles network/status/JSON failures',
    () async {
      final dio = Dio();
      var response = ResponseBody.fromString(
        jsonEncode([release('1.2.1', 9)]),
        200,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.uri.toString(), UpdateCheckerImpl.apiUrl);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: response.statusCode,
                data: response.statusCode == 200
                    ? jsonEncode([release('1.2.1', 9)])
                    : 'rate limit',
              ),
            );
          },
        ),
      );
      final checker = UpdateCheckerImpl(dio: dio);
      expect((await checker.fetchLatest())!.buildNumber, 9);
      response = ResponseBody.fromString('rate limit', 403);
      expect(await checker.fetchLatest(), isNull);
      dio.interceptors.clear();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: '<html>',
              ),
            );
          },
        ),
      );
      expect(await checker.fetchLatest(), isNull);
    },
  );
}
