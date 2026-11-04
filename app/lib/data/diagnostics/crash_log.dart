import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One crash: what failed, where, in which version, when.
class CrashReport {
  const CrashReport({
    required this.time,
    required this.version,
    required this.error,
    required this.stack,
  });

  final DateTime time;
  final String version;
  final String error;
  final String stack;

  factory CrashReport.fromJson(Map<String, dynamic> json) => CrashReport(
    time: DateTime.tryParse('${json['time']}') ?? DateTime(0),
    version: '${json['version'] ?? ''}',
    error: '${json['error'] ?? ''}',
    stack: '${json['stack'] ?? ''}',
  );

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'version': version,
    'error': error,
    'stack': stack,
  };

  /// Plain text for an issue or the clipboard.
  String get text =>
      'Baya $version · ${time.toUtc().toIso8601String()}\n\n$error\n\n$stack';
}

/// Crashes kept on the phone, newest first. Nothing leaves the phone unless
/// the user copies a report or opens an issue with it.
class CrashLog extends ChangeNotifier {
  CrashLog._();
  static final instance = CrashLog._();

  static const _keep = 20;
  File? _file;
  String _version = '';
  List<CrashReport> _reports = const [];

  List<CrashReport> get reports => _reports;

  /// Starts recording uncaught errors. Call once, before runApp.
  Future<void> start({required String version}) async {
    _version = version;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/crash_log.json');
      if (await _file!.exists()) {
        final list = jsonDecode(await _file!.readAsString()) as List;
        _reports = [
          for (final item in list)
            CrashReport.fromJson((item as Map).cast<String, dynamic>()),
        ];
      }
    } catch (_) {
      _reports = const [];
    }
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exception, details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack);
      return false;
    };
  }

  void record(Object error, StackTrace? stack) {
    final report = CrashReport(
      time: DateTime.now(),
      version: _version,
      error: _clip('$error', 2000),
      stack: _clip('${stack ?? ''}', 6000),
    );
    _reports = [report, ..._reports.take(_keep - 1)];
    notifyListeners();
    _save();
  }

  void clear() {
    _reports = const [];
    notifyListeners();
    _save();
  }

  void _save() {
    final file = _file;
    if (file == null) return;
    file
        .writeAsString(jsonEncode([for (final r in _reports) r.toJson()]))
        .ignore();
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  @visibleForTesting
  void resetForTest(List<CrashReport> reports) {
    _reports = reports;
    notifyListeners();
  }
}

/// A GitHub "new issue" link pre-filled with [report], for the user to
/// review and submit themselves.
Uri crashIssueUrl(CrashReport report) {
  final title = report.error.split('\n').first;
  return Uri.https('github.com', '/wianger/baya/issues/new', {
    'title':
        'Crash: ${title.length > 80 ? '${title.substring(0, 80)}…' : title}',
    'body': '```\n${_clipBody(report.text)}\n```',
  });
}

String _clipBody(String text) =>
    text.length <= 5000 ? text : '${text.substring(0, 5000)}…';
