import 'package:app/data/diagnostics/crash_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a crash report becomes a pre-filled GitHub issue', () {
    final report = CrashReport(
      time: DateTime.utc(2026, 11, 4, 9),
      version: '2.7.0 (99)',
      error: 'StateError: Bad state: no element\nmore detail',
      stack: '#0 main (file.dart:1)',
    );
    final url = crashIssueUrl(report);
    expect(url.host, 'github.com');
    expect(url.path, '/wianger/baya/issues/new');
    expect(
      url.queryParameters['title'],
      'Crash: StateError: Bad state: no element',
    );
    expect(url.queryParameters['body'], contains('Baya 2.7.0 (99)'));
    expect(url.queryParameters['body'], contains('#0 main'));
  });

  test('the log keeps the newest reports and can be cleared', () {
    final log = CrashLog.instance..resetForTest(const []);
    for (var i = 0; i < 25; i++) {
      log.record(StateError('crash $i'), StackTrace.current);
    }
    expect(log.reports, hasLength(20));
    expect(log.reports.first.error, contains('crash 24'));
    log.clear();
    expect(log.reports, isEmpty);
  });
}
