import 'dart:convert';

import 'package:app/domain/session_state.dart';

/// Presentation-only interpretation of the loosely typed tool payloads emitted
/// by Pi, Codex, and DeepSeek. It intentionally lives in the UI layer: the
/// protocol keeps these records extensible, while the chat view extracts the
/// fields that are useful to a person.
class ToolContent {
  const ToolContent(this.tool);

  final ToolEvent tool;

  static const _commandKeys = ['command', 'cmd', 'shell_command', 'script'];
  static const _cwdKeys = ['cwd', 'workdir', 'working_directory'];
  static const _metadataKeys = {
    'description',
    'title',
    'kind',
    'approval_required',
    'approval_decision',
  };
  static const _resultTextKeys = [
    'aggregatedOutput',
    'aggregated_output',
    'stdout',
    'output',
    'text',
    'message',
    'result',
    'content',
    'contentItems',
  ];

  Map<String, dynamic>? get arguments => _stringKeyedMap(tool.args);

  bool get isCommand {
    final name = tool.tool.toLowerCase();
    if (name.contains('command') ||
        name.contains('shell') ||
        name.contains('bash') ||
        name.contains('exec')) {
      return true;
    }
    final args = arguments;
    return args != null && _commandKeys.any((key) => _hasText(args[key]));
  }

  bool get isFileChange {
    final name = tool.tool.toLowerCase();
    if (name == 'apply_patch' ||
        name.contains('edit') ||
        name.contains('write') ||
        name.contains('replace') ||
        name.contains('filechange')) {
      return true;
    }
    final args = arguments;
    if (args?['hunks'] is Iterable) return true;
    if (_hasFileChanges(args?['changes'])) return true;
    return _hasFileChanges(_stringKeyedMap(tool.result)?['changes']);
  }

  bool get isAgentMessage {
    final name = tool.tool.toLowerCase();
    return name.contains('message') || name.contains('agent');
  }

  /// Details from these tools are normally prose written by one agent to
  /// another. Terminal output, patches, paths and code remain monospace.
  bool get usesProseDetails {
    if (isCommand || isFileChange) return false;
    if (isAgentMessage) return true;
    final name = tool.tool.toLowerCase();
    return name.contains('search') ||
        name.contains('web') ||
        name.contains('query');
  }

  bool get awaitingApproval =>
      tool.status == ToolEventStatus.pending &&
      arguments?['approval_required'] == true;

  String get toolName {
    final name = tool.tool.trim();
    return name.isEmpty ? 'Tool' : name;
  }

  String? get description {
    final args = arguments;
    if (args == null) return null;
    for (final key in const ['description', 'title']) {
      final value = args[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  String get title {
    if (awaitingApproval) return 'Waiting for approval';
    final explicit = description;
    if (explicit != null) return explicit;
    final name = tool.tool.toLowerCase();
    final running =
        tool.status == ToolEventStatus.pending ||
        tool.status == ToolEventStatus.allowed;
    if (isCommand) return running ? 'Running command' : 'Ran command';
    if (isAgentMessage) {
      return running ? 'Messaging agent' : 'Messaged agent';
    }
    if (name.contains('read')) return running ? 'Reading file' : 'Read file';
    if (isFileChange) {
      return running ? 'Editing files' : 'Edited files';
    }
    if (name.contains('search') || name.contains('grep')) {
      return running ? 'Searching' : 'Searched';
    }
    return '${running ? 'Using' : 'Used'} $toolName';
  }

  String get statusLabel => switch (tool.status) {
    ToolEventStatus.pending => awaitingApproval ? 'Waiting' : 'Running',
    ToolEventStatus.allowed => 'Running',
    ToolEventStatus.completed => 'Completed',
    ToolEventStatus.failed => 'Failed',
    ToolEventStatus.denied => 'Denied',
    ToolEventStatus.expired => 'Expired',
  };

  String? get command {
    final rawArgs = tool.args;
    if (rawArgs is String && rawArgs.trim().isNotEmpty) return rawArgs;
    final args = arguments;
    if (args == null) return null;
    for (final key in _commandKeys) {
      final value = args[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  String? get workingDirectory {
    final args = arguments;
    if (args == null) return null;
    for (final key in _cwdKeys) {
      final value = args[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  /// Arguments worth showing in the detail sheet. Transport and approval
  /// metadata belong in the header/status treatment, not beside user input.
  Map<String, dynamic>? get visibleArguments {
    final args = arguments;
    if (args == null) return null;
    final visible = <String, dynamic>{};
    for (final entry in args.entries) {
      if (_metadataKeys.contains(entry.key)) continue;
      if (isCommand &&
          (_commandKeys.contains(entry.key) || _cwdKeys.contains(entry.key))) {
        continue;
      }
      visible[entry.key] = entry.value;
    }
    if (visible.isEmpty) return null;
    final nestedArguments = _stringKeyedMap(visible['arguments']);
    if (nestedArguments != null && visible.length == 1) {
      return nestedArguments;
    }
    return visible;
  }

  String? get inputText {
    final rawArgs = tool.args;
    if (rawArgs is String && rawArgs.trim().isNotEmpty) return rawArgs;
    final visible = visibleArguments;
    if (visible == null) return null;
    if (visible.length == 1) {
      final value = visible.values.single;
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return _readableJson(visible);
  }

  String? get changesText {
    final args = arguments;
    final result = _stringKeyedMap(tool.result);
    final rawChanges = args?['changes'] ?? result?['changes'];
    final sections = <String>[];

    final codexChanges = _fileChangesText(rawChanges);
    if (codexChanges != null) sections.add(codexChanges);

    final hunks = args?['hunks'];
    if (hunks is Iterable) {
      final path = _stringValue(args!, const ['file_path', 'path']) ?? toolName;
      final lines = <String>[];
      for (final hunk in hunks) {
        final hunkMap = _stringKeyedMap(hunk);
        final rawLines = hunkMap?['lines'];
        if (rawLines is! Iterable) continue;
        if (lines.isNotEmpty) lines.add('...');
        for (final rawLine in rawLines) {
          final line = _stringKeyedMap(rawLine);
          if (line == null) continue;
          final text = line['text'];
          if (text is! String) continue;
          final kind = line['kind'];
          final sign = switch (kind) {
            'remove' => '-',
            'add' => '+',
            _ => ' ',
          };
          final lineNumber = line['oldLine'] ?? line['newLine'];
          final number =
              (lineNumber is num ? lineNumber.toInt().toString() : '').padLeft(
                4,
              );
          lines.add('$sign$number  $text');
        }
      }
      if (lines.isNotEmpty) {
        sections.add('M $path\n${lines.join('\n')}');
      }
    }
    return sections.isEmpty ? null : sections.join('\n\n');
  }

  ToolOutput get output {
    final result = tool.result;
    if (result == null) return const ToolOutput();

    if (result is Map) {
      final map = _stringKeyedMap(result)!;
      final stderr = _textFrom(map['stderr']);
      final text = _firstText(map, _resultTextKeys);
      if (text != null || stderr != null) {
        return ToolOutput(text: text, stderr: stderr);
      }
      if (changesText != null) return const ToolOutput();
      if (map['error'] != null) return const ToolOutput();
    }

    final text = _textFrom(result);
    if (text == null) return const ToolOutput();
    if (const {
      'completed',
      'success',
      'succeeded',
      'ok',
    }.contains(text.trim().toLowerCase())) {
      return const ToolOutput();
    }
    return ToolOutput(text: text);
  }

  String? get error {
    final direct = tool.error;
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    final result = tool.result;
    if (result is Map) {
      final map = _stringKeyedMap(result)!;
      final value = _textFrom(map['error']);
      if (value != null) return value;
    }
    return null;
  }

  /// A compact one-line summary for collapsed activity rows. Commands always
  /// show the command itself; a prose description remains in the detail title.
  String? get preview {
    if (isCommand) {
      final commandText = command;
      if (commandText != null) return _oneLine(commandText);
    }
    if (isFileChange) {
      final paths = _changedPaths;
      if (paths.isNotEmpty) {
        final first = _oneLine(paths.first);
        return paths.length == 1
            ? first
            : '$first  ·  +${paths.length - 1} more';
      }
    }
    final rawArgs = tool.args;
    if (rawArgs is String && rawArgs.trim().isNotEmpty) {
      return _oneLine(rawArgs);
    }
    final args = arguments;
    if (args != null) {
      for (final key in const [
        'description',
        'title',
        'prompt',
        'query',
        'path',
        'file_path',
      ]) {
        final value = args[key];
        if (value is String && value.trim().isNotEmpty) {
          return _oneLine(value);
        }
      }
    }
    final input = inputText;
    if (input != null) return _oneLine(input);
    final failure = error;
    if (failure != null) return _oneLine(failure);
    return null;
  }

  List<String> get _changedPaths {
    final args = arguments;
    final result = _stringKeyedMap(tool.result);
    final raw = args?['changes'] ?? result?['changes'];
    if (raw is Map) {
      return [
        for (final entry in raw.entries)
          if (entry.key is String && entry.key.trim().isNotEmpty)
            entry.key.trim(),
      ];
    }
    if (raw is Iterable) {
      final paths = <String>[];
      for (final entry in raw) {
        final map = _stringKeyedMap(entry);
        if (map == null) continue;
        final path = _stringValue(map, const ['path', 'file_path'])?.trim();
        if (path != null && path.isNotEmpty) paths.add(path);
      }
      return paths;
    }
    final path = args?['file_path'] ?? args?['path'];
    return path is String && path.trim().isNotEmpty ? [path.trim()] : const [];
  }

  static bool _hasFileChanges(dynamic value) {
    if (value is Map) return value.isNotEmpty;
    if (value is Iterable) return value.isNotEmpty;
    return false;
  }

  static String? _fileChangesText(dynamic raw) {
    if (raw is Map && raw.isNotEmpty) {
      final sections = <String>[];
      for (final entry in raw.entries) {
        final path = entry.key is String ? (entry.key as String).trim() : '';
        if (path.isEmpty) continue;
        sections.add(_changeSection(path, _stringKeyedMap(entry.value)));
      }
      return sections.isEmpty ? null : sections.join('\n\n');
    }
    if (raw is Iterable) {
      final sections = <String>[];
      for (final item in raw) {
        final change = _stringKeyedMap(item);
        if (change == null) continue;
        final path =
            _stringValue(change, const ['path', 'file_path'])?.trim() ?? '';
        if (path.isEmpty) continue;
        sections.add(_changeSection(path, change));
      }
      return sections.isEmpty ? null : sections.join('\n\n');
    }
    return null;
  }

  static String _changeSection(String path, Map<String, dynamic>? change) {
    final metadata = change ?? const <String, dynamic>{};
    final kind =
        _stringValue(metadata, const [
          'type',
          'kind',
          'change_type',
        ])?.trim().toLowerCase() ??
        'update';
    final marker = switch (kind) {
      'add' || 'added' || 'create' || 'created' => 'A',
      'delete' || 'deleted' || 'remove' || 'removed' => 'D',
      'move' || 'rename' || 'renamed' => 'R',
      _ => 'M',
    };
    final movePath = _stringValue(metadata, const [
      'move_path',
      'new_path',
    ])?.trim();
    final heading = '$marker $path${movePath == null ? '' : ' -> $movePath'}';
    final diff = _stringValue(metadata, const [
      'unified_diff',
      'unifiedDiff',
      'diff',
      'patch',
    ]);
    if (diff != null) {
      return '$heading\n${diff.trimRight()}';
    }
    final content = metadata['content'];
    if (content is String && content.isNotEmpty) {
      return '$heading\n${content.trimRight()}';
    }
    return heading;
  }

  static String? _firstText(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = _textFrom(map[key]);
      if (value != null) return value;
    }
    return null;
  }

  static String? _textFrom(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      return value.trim().isEmpty ? null : value;
    }
    if (value is Iterable) {
      final parts = <String>[];
      for (final item in value) {
        final text = _textFrom(item);
        if (text != null) parts.add(text);
      }
      if (parts.isNotEmpty) return parts.join('\n');
    }
    if (value is Map) {
      final map = _stringKeyedMap(value)!;
      for (final key in const [
        'aggregatedOutput',
        'aggregated_output',
        'stdout',
        'output',
        'text',
        'message',
        'result',
        'content',
        'contentItems',
      ]) {
        final text = _textFrom(map[key]);
        if (text != null) return text;
      }
      return _readableJson(map);
    }
    return value.toString();
  }

  static String? _readableJson(Map<String, dynamic> value) {
    if (value.isEmpty) return null;
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } on Object {
      return value.toString();
    }
  }

  static String? _stringValue(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      final entry = value[key];
      if (entry is String && entry.trim().isNotEmpty) return entry;
    }
    return null;
  }

  static Map<String, dynamic>? _stringKeyedMap(dynamic value) {
    if (value is! Map || value.isEmpty) return null;
    return {
      for (final entry in value.entries)
        if (entry.key is String)
          entry.key as String: entry.value
        else
          entry.key.toString(): entry.value,
    };
  }

  static bool _hasText(dynamic value) =>
      value is String && value.trim().isNotEmpty;

  static String _oneLine(String value) {
    return value.trim().replaceAll(RegExp(r'\s*\n+\s*'), ' ');
  }
}

class ToolOutput {
  const ToolOutput({this.text, this.stderr});

  final String? text;
  final String? stderr;

  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) &&
      (stderr == null || stderr!.trim().isEmpty);
}
