import 'dart:convert';

import 'package:app/domain/session_state.dart';

/// Presentation-only interpretation of the loosely typed tool payloads emitted
/// by Pi, Codex, and DeepSeek. The protocol intentionally keeps these records
/// extensible; this layer turns their common shapes into human-readable text.
class ToolContent {
  const ToolContent(this.tool);

  final ToolEvent tool;

  static const _argumentWrapperKeys = {
    'arguments',
    'rawInput',
    'raw_input',
    'toolInput',
    'tool_input',
    'parameters',
    'params',
    'payload',
  };
  static const _commandKeys = ['command', 'cmd', 'shell_command', 'script'];
  static const _cwdKeys = ['cwd', 'workdir', 'working_directory'];
  static const _pathKeys = [
    'path',
    'file_path',
    'filePath',
    'filename',
    'target_file',
    'targetFile',
  ];
  static const _metadataKeys = {
    'description',
    'title',
    'kind',
    'approval_required',
    'approval_decision',
    'status',
  };
  static const _resultTextKeys = [
    'rawOutput',
    'raw_output',
    'aggregatedOutput',
    'aggregated_output',
    'stdout',
    'output',
    'text',
    'message',
    'result',
    'value',
    'content',
    'contentItems',
  ];
  static const _agentBodyKeys = ['body', 'message', 'prompt', 'text', 'input'];
  static const _oldTextKeys = [
    'oldText',
    'old_string',
    'oldString',
    'old_text',
    'original',
    'before',
  ];
  static const _newTextKeys = [
    'newText',
    'new_string',
    'newString',
    'new_text',
    'replacement',
    'after',
  ];

  /// Flattens the wrappers used by the three supported agents. Some tools put
  /// useful fields in `arguments`, `rawInput`, or a JSON-encoded string while
  /// retaining metadata beside them.
  Map<String, dynamic>? get arguments {
    final source = _argumentMap(tool.args);
    if (source == null || source.isEmpty) return null;
    final flattened = <String, dynamic>{};
    _mergeArguments(flattened, source);
    return flattened.isEmpty ? null : flattened;
  }

  bool get isCommand {
    final name = _normalizedName;
    if (name.contains('command') ||
        name.contains('shell') ||
        name.contains('bash') ||
        name.contains('powershell') ||
        name.contains('exec')) {
      return true;
    }
    final args = arguments;
    return args != null && _commandKeys.any((key) => _hasText(args[key]));
  }

  bool get isFileChange {
    final name = _normalizedName;
    if (name.contains('edit') ||
        name.contains('write') ||
        name.contains('replace') ||
        name.contains('patch') ||
        name.contains('filechange') ||
        name.contains('file_change')) {
      return true;
    }
    final args = arguments;
    final result = _argumentMap(tool.result);
    return _hasChangePayload(args) || _hasChangePayload(result);
  }

  bool get isRead {
    final name = _normalizedName;
    return !isSearch &&
        !isFileChange &&
        (name == 'read' ||
            name.contains('readfile') ||
            name.contains('read_file') ||
            name.contains('viewfile') ||
            name.contains('view_file') ||
            name == 'cat');
  }

  bool get isSearch {
    final name = _normalizedName;
    return name.contains('search') ||
        name.contains('grep') ||
        name.contains('glob') ||
        (name.contains('find') && !isFileChange);
  }

  bool get isWeb => _normalizedName.contains('web');

  bool get isAgentMessage {
    if (isCommand || isFileChange) return false;
    final name = _normalizedName;
    return name.contains('message') ||
        name.contains('agent_send') ||
        name.contains('send_message') ||
        name.contains('agent_request') ||
        name == 'agentsend';
  }

  /// Details from these tools are normally prose written by one agent to
  /// another. Terminal output, patches, paths and code remain monospace.
  bool get usesProseDetails {
    if (isCommand || isFileChange) return false;
    if (isAgentMessage || isWeb) return true;
    final args = arguments;
    return args != null &&
        _agentBodyKeys.any((key) => key != 'input' && _hasText(args[key]));
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
      if (value is String &&
          value.trim().isNotEmpty &&
          !_isGenericTitle(value)) {
        return value.trim();
      }
    }
    return null;
  }

  String get title {
    if (awaitingApproval) return 'Waiting for approval';
    final explicit = description;
    if (explicit != null) return explicit;
    final running =
        tool.status == ToolEventStatus.pending ||
        tool.status == ToolEventStatus.allowed;
    if (isCommand) return running ? 'Running command' : 'Ran command';
    if (isFileChange) {
      final count = changedPaths.length;
      if (count > 1) {
        return running ? 'Editing $count files' : 'Edited $count files';
      }
      return running ? 'Editing file' : 'Edited file';
    }
    if (isAgentMessage) {
      return running ? 'Messaging agent' : 'Messaged agent';
    }
    if (isRead) return running ? 'Reading file' : 'Read file';
    if (isSearch) {
      return running
          ? (isWeb ? 'Searching the web' : 'Searching files')
          : (isWeb ? 'Searched the web' : 'Searched files');
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
    if (rawArgs is String &&
        rawArgs.trim().isNotEmpty &&
        !_looksLikeJsonObject(rawArgs)) {
      return rawArgs.trim();
    }
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

  String? get path {
    final args = arguments;
    if (args != null) {
      final direct = _stringValue(args, _pathKeys);
      if (direct != null) return direct;
      final editPath = _firstEditPath(args['edits']);
      if (editPath != null) return editPath;
    }
    return changedPaths.firstOrNull;
  }

  List<String> get changedPaths {
    final paths = <String>[];
    void add(String? value) {
      final path = value?.trim();
      if (path != null && path.isNotEmpty && !paths.contains(path)) {
        paths.add(path);
      }
    }

    final sources = [arguments, _argumentMap(tool.result)];
    for (final source in sources) {
      if (source == null) continue;
      add(_stringValue(source, _pathKeys));
      final edits = _iterable(source['edits']);
      for (final edit in edits) {
        add(_stringValue(_map(edit) ?? const {}, _pathKeys));
      }
      final changes = source['changes'];
      if (changes is Map) {
        for (final key in changes.keys) {
          if (key is String) add(key);
        }
      } else {
        for (final change in _iterable(changes)) {
          add(_stringValue(_map(change) ?? const {}, _pathKeys));
        }
      }
    }
    return paths;
  }

  /// Arguments worth exposing outside a semantic section. Transport and
  /// approval metadata belong in the header/status treatment.
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
    return visible;
  }

  String get inputLabel {
    if (isAgentMessage) return 'Message';
    if (isRead) return 'File';
    if (isSearch) return isWeb ? 'Query' : 'Search';
    return 'Input';
  }

  String? get inputText {
    final rawArgs = tool.args;
    if (rawArgs is String &&
        rawArgs.trim().isNotEmpty &&
        !_looksLikeJsonObject(rawArgs)) {
      return rawArgs;
    }
    final args = arguments;
    if (args == null) return null;

    if (isRead) {
      final file = path;
      if (file == null) return null;
      final offset = _intValue(args, const [
        'offset',
        'start_line',
        'startLine',
      ]);
      final limit = _intValue(args, const ['limit', 'line_count', 'lineCount']);
      if (offset == null && limit == null) return file;
      final start = offset ?? 1;
      final range = limit == null
          ? 'from line $start'
          : 'lines $start-${start + limit - 1}';
      return '$file\n$range';
    }

    if (isSearch) {
      final query = _stringValue(args, const [
        'query',
        'pattern',
        'search',
        'glob',
        'action',
      ]);
      final scope = path ?? _stringValue(args, const ['cwd', 'directory']);
      if (query != null && scope != null) return '$query\nin $scope';
      return query ?? scope;
    }

    if (isAgentMessage) {
      final recipient = _stringValue(args, const ['to', 'recipient', 'target']);
      final body = _textFrom(_firstValue(args, _agentBodyKeys));
      if (recipient != null && body != null) return 'To $recipient\n\n$body';
      return body ?? recipient;
    }

    if (isFileChange || isCommand) return null;
    return _readableInput(args);
  }

  String? get changesText {
    final args = arguments;
    final result = _argumentMap(tool.result);
    final sections = <String>[];

    final rawChanges = args?['changes'] ?? result?['changes'];
    final codexChanges = _fileChangesText(rawChanges);
    if (codexChanges != null) sections.add(codexChanges);

    final hunks = args?['hunks'] ?? result?['hunks'];
    if (hunks is Iterable) {
      final hunkText = _hunksText(path ?? toolName, hunks);
      if (hunkText != null) sections.add(hunkText);
    }

    if (args != null) {
      final editText = _editText(args);
      if (editText != null) sections.add(editText);
    }
    if (result != null && result != args) {
      final resultEditText = _editText(result);
      if (resultEditText != null &&
          !sections.any((section) => section == resultEditText)) {
        sections.add(resultEditText);
      }
    }

    return sections.isEmpty ? null : sections.join('\n\n');
  }

  ToolOutput get output {
    if (changesText != null) return const ToolOutput();
    final result = tool.result;
    if (result == null) return const ToolOutput();

    if (result is Map) {
      final map = _map(result)!;
      if (isAgentMessage) {
        final delivery = _agentDeliveryText(map);
        if (delivery != null) return ToolOutput(text: delivery);
      }
      final stderr = _textFrom(map['stderr']);
      final text = _firstText(map, _resultTextKeys);
      if (text != null || stderr != null) {
        return ToolOutput(text: text, stderr: stderr);
      }
      if (map['error'] != null) {
        return const ToolOutput();
      }
      if (_isNoopResult(map)) return const ToolOutput();
    }

    final text = _textFrom(result);
    if (text == null || _isTerminalStatus(text)) {
      return const ToolOutput();
    }
    return ToolOutput(text: text);
  }

  String? get error {
    final direct = tool.error;
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    final result = _argumentMap(tool.result);
    if (result == null) return null;
    final value = _textFrom(
      result['error'] ?? result['errorMessage'] ?? result['error_message'],
    );
    if (value != null) return value;
    if (result['is_error'] == true || result['isError'] == true) {
      return _textFrom(result['message'] ?? result['content']);
    }
    return null;
  }

  /// A compact one-line summary for collapsed activity rows. Commands always
  /// show the command itself; file tools identify their target.
  String? get preview {
    if (isCommand) {
      final commandText = command;
      if (commandText != null) return _oneLine(commandText);
    }
    if (isFileChange) {
      final paths = changedPaths;
      if (paths.isNotEmpty) {
        final first = _oneLine(paths.first);
        return paths.length == 1
            ? first
            : '$first  ·  +${paths.length - 1} more';
      }
    }
    if (isRead) {
      final file = path;
      if (file != null) return _oneLine(file);
    }
    if (isSearch) {
      final args = arguments;
      final query = args == null
          ? null
          : _stringValue(args, const [
              'query',
              'pattern',
              'search',
              'glob',
              'action',
            ]);
      if (query != null) return _oneLine(query);
    }
    final input = inputText;
    if (input != null) return _oneLine(input);
    final failure = error;
    if (failure != null) return _oneLine(failure);
    return null;
  }

  String get _normalizedName => _normalizeName(tool.tool);

  bool _isGenericTitle(String value) {
    final normalized = _normalizeName(value);
    if (normalized.isEmpty) return true;
    if (normalized == _normalizedName) return true;
    return const {
      'edit',
      'editfile',
      'editingfile',
      'write',
      'writefile',
      'read',
      'readfile',
      'search',
      'searchfiles',
      'command',
      'runcommand',
      'tool',
      'agent',
    }.contains(normalized);
  }

  static String _normalizeName(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static bool _hasChangePayload(Map<String, dynamic>? source) {
    if (source == null) return false;
    if (_hasFileChanges(source['changes'])) return true;
    if (_iterable(source['hunks']).isNotEmpty) return true;
    if (_iterable(source['edits']).isNotEmpty) return true;
    final path = _stringValue(source, _pathKeys);
    final content = source['content'];
    return path != null && content is String;
  }

  static String? _editText(Map<String, dynamic> source) {
    final filePath =
        _stringValue(source, _pathKeys) ?? _firstEditPath(source['edits']);
    final edits = _iterable(source['edits']);
    final replacements = <({String oldText, String newText})>[];
    if (edits.isNotEmpty) {
      for (final rawEdit in edits) {
        final edit = _map(rawEdit);
        if (edit == null) continue;
        final oldText = _stringValue(edit, _oldTextKeys);
        final newText = _stringValue(edit, _newTextKeys);
        if (oldText != null && newText != null) {
          replacements.add((oldText: oldText, newText: newText));
        }
      }
    }
    if (replacements.isEmpty) {
      final oldText = _stringValue(source, _oldTextKeys);
      final newText = _stringValue(source, _newTextKeys);
      if (oldText != null && newText != null) {
        replacements.add((oldText: oldText, newText: newText));
      }
    }

    if (replacements.isNotEmpty) {
      final file = filePath?.trim();
      if (file == null || file.isEmpty) return null;
      final blocks = <String>[];
      for (var index = 0; index < replacements.length; index++) {
        final replacement = replacements[index];
        final heading = replacements.length > 1
            ? '@@ edit ${index + 1} @@\n'
            : '';
        blocks.add(
          '$heading${_replacementDiff(replacement.oldText, replacement.newText)}',
        );
      }
      return 'M $file\n${blocks.join('\n\n')}';
    }

    final content = source['content'];
    final file = filePath?.trim();
    if (file != null &&
        file.isNotEmpty &&
        content is String &&
        content.isNotEmpty) {
      final lines = content
          .trimRight()
          .split('\n')
          .map((line) => '+$line')
          .join('\n');
      return 'A $file\n$lines';
    }
    return null;
  }

  static String? _hunksText(String filePath, Iterable<dynamic> hunks) {
    final lines = <String>[];
    for (final hunk in hunks) {
      final hunkMap = _map(hunk);
      final rawLines = hunkMap?['lines'];
      if (rawLines is! Iterable) continue;
      if (lines.isNotEmpty) lines.add('...');
      for (final rawLine in rawLines) {
        final line = _map(rawLine);
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
        final number = (lineNumber is num ? lineNumber.toInt().toString() : '')
            .padLeft(4);
        lines.add('$sign$number  $text');
      }
    }
    return lines.isEmpty ? null : 'M ${filePath.trim()}\n${lines.join('\n')}';
  }

  static String _replacementDiff(String oldText, String newText) {
    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');
    var prefix = 0;
    while (prefix < oldLines.length &&
        prefix < newLines.length &&
        oldLines[prefix] == newLines[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldLines.length - prefix &&
        suffix < newLines.length - prefix &&
        oldLines[oldLines.length - 1 - suffix] ==
            newLines[newLines.length - 1 - suffix]) {
      suffix++;
    }

    final firstContext = (prefix - 2).clamp(0, prefix);
    final lastOld = oldLines.length - suffix;
    final lastNew = newLines.length - suffix;
    final result = <String>[
      for (var index = firstContext; index < prefix; index++)
        ' ${oldLines[index]}',
      for (var index = prefix; index < lastOld; index++) '-${oldLines[index]}',
      for (var index = prefix; index < lastNew; index++) '+${newLines[index]}',
      for (var index = 0; index < suffix.clamp(0, 2); index++)
        ' ${oldLines[lastOld + index]}',
    ];
    if (result.isEmpty) {
      return '${oldText.split('\n').map((line) => '-$line').join('\n')}\n'
          '${newText.split('\n').map((line) => '+$line').join('\n')}';
    }
    return result.join('\n');
  }

  static String? _firstEditPath(dynamic edits) {
    for (final edit in _iterable(edits)) {
      final path = _stringValue(_map(edit) ?? const {}, _pathKeys);
      if (path != null) return path;
    }
    return null;
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
        sections.add(_changeSection(path, _map(entry.value)));
      }
      return sections.isEmpty ? null : sections.join('\n\n');
    }
    if (raw is Iterable) {
      final sections = <String>[];
      for (final item in raw) {
        final change = _map(item);
        if (change == null) continue;
        final path = _stringValue(change, _pathKeys)?.trim() ?? '';
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
      if (marker == 'A') {
        final addition = content
            .trimRight()
            .split('\n')
            .map((line) => '+$line')
            .join('\n');
        return '$heading\n$addition';
      }
      return '$heading\n${content.trimRight()}';
    }
    return heading;
  }

  static String? _readableInput(Map<String, dynamic> value) {
    final lines = <String>[];
    for (final entry in value.entries) {
      if (_metadataKeys.contains(entry.key)) continue;
      final raw = entry.value;
      if (raw is String && raw.trim().isNotEmpty) {
        lines.add(raw.trim());
      } else if (raw is num || raw is bool) {
        lines.add('${entry.key}: $raw');
      }
      if (lines.length == 4) break;
    }
    if (lines.isNotEmpty) return lines.join('\n');
    return _readableJson(value);
  }

  static String? _agentDeliveryText(Map<String, dynamic> value) {
    final status = _stringValue(value, const ['status'])?.toLowerCase();
    if (status == null) return null;
    final target = _stringValue(value, const ['target', 'to', 'recipient']);
    return switch (status) {
      'received' =>
        target == null ? 'Message delivered.' : 'Delivered to $target.',
      'sent' => 'Message sent.',
      'denied' =>
        target == null
            ? 'The recipient denied the message.'
            : '$target denied the message.',
      'timeout' =>
        target == null
            ? 'Message delivery timed out.'
            : 'Message delivery to $target timed out.',
      _ => null,
    };
  }

  static bool _isNoopResult(Map<String, dynamic> value) {
    const metadataKeys = {
      'ok',
      'success',
      'succeeded',
      'completed',
      'status',
      'exit_code',
      'exitCode',
      'duration_ms',
      'durationMs',
      'processed',
      'error',
    };
    if (value.keys.any((key) => !metadataKeys.contains(key))) return false;
    return value['error'] == null;
  }

  static bool _isTerminalStatus(String value) {
    return const {
      'completed',
      'success',
      'succeeded',
      'ok',
      'done',
    }.contains(value.trim().toLowerCase());
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
      final map = _map(value)!;
      for (final key in const [
        'rawOutput',
        'raw_output',
        'aggregatedOutput',
        'aggregated_output',
        'stdout',
        'output',
        'text',
        'message',
        'result',
        'value',
        'content',
        'contentItems',
        'items',
      ]) {
        final text = _textFrom(map[key]);
        if (text != null) return text;
      }
      return _isNoopResult(map) ? null : _readableJson(map);
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

  static int? _intValue(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      final entry = value[key];
      if (entry is num) return entry.toInt();
      if (entry is String) return int.tryParse(entry);
    }
    return null;
  }

  static dynamic _firstValue(Map<String, dynamic> value, List<String> keys) {
    for (final key in keys) {
      final entry = value[key];
      if (entry != null) return entry;
    }
    return null;
  }

  static Map<String, dynamic>? _map(dynamic value) {
    if (value is! Map || value.isEmpty) return null;
    return {
      for (final entry in value.entries)
        if (entry.key is String)
          entry.key as String: entry.value
        else
          entry.key.toString(): entry.value,
    };
  }

  static Map<String, dynamic>? _argumentMap(dynamic value) {
    final direct = _map(value);
    if (direct != null) return direct;
    if (value is! String || value.trim().isEmpty) return null;
    try {
      return _map(jsonDecode(value));
    } on Object {
      return null;
    }
  }

  static void _mergeArguments(
    Map<String, dynamic> destination,
    Map<String, dynamic> source,
  ) {
    for (final entry in source.entries) {
      if (_argumentWrapperKeys.contains(entry.key)) {
        final nested = _argumentMap(entry.value);
        if (nested != null) {
          _mergeArguments(destination, nested);
        }
        continue;
      }
      destination[entry.key] = entry.value;
    }
  }

  static Iterable<dynamic> _iterable(dynamic value) {
    if (value is Iterable) return value;
    if (value is Map) return [value];
    return const [];
  }

  static bool _hasText(dynamic value) =>
      value is String && value.trim().isNotEmpty;

  static bool _looksLikeJsonObject(String value) {
    final trimmed = value.trim();
    return trimmed.startsWith('{') && trimmed.endsWith('}');
  }

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
