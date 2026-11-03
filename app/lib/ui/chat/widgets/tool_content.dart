import 'dart:convert';

import 'package:app/acp/acp.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';

/// How a tool call reads in the chat, derived from the ACP fields every
/// agent reports: `kind`, `title`, `content` (text and diffs), `locations`
/// and the raw input/output.
class ToolContent {
  const ToolContent(this.tool);

  final ToolEvent tool;

  Map<String, dynamic>? get arguments => tool.rawInput is Map
      ? (tool.rawInput as Map).cast<String, dynamic>()
      : null;

  bool get isCommand => tool.kind == ToolKind.execute;

  bool get isFileChange =>
      tool.kind == ToolKind.edit ||
      tool.kind == ToolKind.delete ||
      tool.kind == ToolKind.move ||
      _diffs.isNotEmpty;

  bool get isRead => tool.kind == ToolKind.read;
  bool get isSearch => tool.kind == ToolKind.search;

  /// Reasoning and other prose read better in the body font.
  bool get usesProseDetails => tool.kind == ToolKind.think;

  bool get awaitingApproval => tool.awaitingApproval;

  String get toolName => switch (tool.kind) {
    ToolKind.read => appL10n.toolRead,
    ToolKind.edit => appL10n.toolEdit,
    ToolKind.delete => appL10n.toolDelete,
    ToolKind.move => appL10n.toolMove,
    ToolKind.search => appL10n.toolSearch,
    ToolKind.execute => appL10n.toolExecute,
    ToolKind.think => appL10n.toolThink,
    ToolKind.fetch => appL10n.toolFetch,
    ToolKind.switchMode => appL10n.toolSwitchMode,
    ToolKind.other => appL10n.toolOther,
  };

  String get title {
    final title = tool.title.trim();
    return title.isEmpty ? toolName : _oneLine(title);
  }

  /// The command line of a shell call.
  String? get command {
    if (!isCommand) return null;
    final raw = _first(arguments, const ['command', 'cmd', 'script']);
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    if (raw is List) return raw.map((part) => '$part').join(' ');
    return tool.title.trim().isEmpty ? null : tool.title.trim();
  }

  String? get workingDirectory {
    final raw = _first(arguments, const [
      'cwd',
      'workdir',
      'working_directory',
    ]);
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  String? get path => changedPaths.firstOrNull;

  List<String> get changedPaths => {
    for (final diff in _diffs) diff.path,
    for (final location in tool.locations) location.path,
  }.toList();

  /// The call's input as labelled fields, leaving out what the row already
  /// shows as a command or a diff.
  List<({String label, String value})> get inputFields {
    final raw = tool.rawInput;
    if (raw == null) return const [];
    if (raw is String) {
      return raw.trim().isEmpty
          ? const []
          : [(label: appL10n.input, value: raw)];
    }
    if (raw is! Map) return [(label: appL10n.input, value: _show(raw))];
    const shownElsewhere = {'command', 'cmd', 'script', 'cwd', 'workdir'};
    return [
      for (final MapEntry(:key, :value) in raw.entries)
        if (value != null &&
            !(isCommand && shownElsewhere.contains(key)) &&
            !(value is String && value.trim().isEmpty) &&
            !(value is Iterable && value.isEmpty) &&
            !(value is Map && value.isEmpty))
          (label: _label('$key'), value: _show(value)),
    ];
  }

  static String _label(String key) {
    final words = key
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (m) => '${m[1]} ${m[2]}',
        )
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .trim()
        .toLowerCase();
    return words.isEmpty ? key : words[0].toUpperCase() + words.substring(1);
  }

  static String _show(Object? value) => switch (value) {
    final String text => text,
    num() || bool() => '$value',
    final Iterable<Object?> items
        when items.every((i) => i is String || i is num) =>
      items.join(', '),
    _ => const JsonEncoder.withIndent('  ').convert(value),
  };

  /// Unified-style diff of every file the call changed.
  String? get changesText {
    if (_diffs.isEmpty) return null;
    return [
      for (final diff in _diffs)
        '${diff.oldText == null ? 'A' : 'M'} ${diff.path}\n'
            '${_replacementDiff(diff.oldText ?? '', diff.newText)}',
    ].join('\n\n');
  }

  ToolOutput get output {
    final terminal = tool.terminal;
    if (terminal != null) {
      final status = !terminal.exited
          ? ''
          : terminal.exitCode != null
          ? '\n[exit ${terminal.exitCode}]'
          : terminal.signal != null
          ? '\n[${terminal.signal}]'
          : '';
      return ToolOutput(
        text:
            '${terminal.truncated ? '…\n' : ''}${cleanTerminalText(terminal.output).trimRight()}$status',
      );
    }
    final texts = [
      for (final item in tool.content)
        if (item is ToolCallText && item.content.displayText.trim().isNotEmpty)
          cleanTerminalText(item.content.displayText),
    ];
    if (texts.isNotEmpty) return ToolOutput(text: texts.join('\n'));
    final raw = tool.rawOutput;
    if (raw is String) return ToolOutput(text: cleanTerminalText(raw));
    if (raw is Map) {
      final map = raw.cast<String, dynamic>();
      final text = _first(map, const [
        'output',
        'stdout',
        'content',
        'result',
        'text',
      ]);
      final stderr = _first(map, const ['stderr']);
      return ToolOutput(
        text: text is String
            ? cleanTerminalText(text)
            : (text == null && stderr == null
                  ? const JsonEncoder.withIndent('  ').convert(map)
                  : null),
        stderr: stderr is String ? cleanTerminalText(stderr) : null,
      );
    }
    return const ToolOutput();
  }

  /// Failed calls with nothing else to show still say so.
  String? get error => tool.status == ToolEventStatus.failed && output.isEmpty
      ? appL10n.failed
      : null;

  /// A file the title does not already name, shown beside it.
  String? get detailLine {
    final file = path;
    if (file == null || isCommand) return null;
    final name = file.split(RegExp(r'[/\\]')).last;
    return title.contains(name) ? null : name;
  }

  /// Lines added and removed across the call's diffs.
  ({int added, int removed})? get diffStats {
    if (_diffs.isEmpty) return null;
    var added = 0;
    var removed = 0;
    for (final line in changesText!.split('\n')) {
      if (line.startsWith('+')) added++;
      if (line.startsWith('-')) removed++;
    }
    return (added: added, removed: removed);
  }

  List<ToolCallDiff> get _diffs => [
    for (final item in tool.content)
      if (item is ToolCallDiff) item,
  ];

  static Object? _first(Map<String, dynamic>? map, List<String> keys) {
    if (map == null) return null;
    for (final key in keys) {
      final value = map[key];
      if (value != null) return value;
    }
    return null;
  }

  static String _replacementDiff(String oldText, String newText) {
    final oldLines = oldText.isEmpty ? <String>[] : oldText.split('\n');
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
    return [
      for (var index = firstContext; index < prefix; index++)
        ' ${oldLines[index]}',
      for (var index = prefix; index < lastOld; index++) '-${oldLines[index]}',
      for (var index = prefix; index < lastNew; index++) '+${newLines[index]}',
      for (var index = 0; index < suffix.clamp(0, 2); index++)
        ' ${oldLines[lastOld + index]}',
    ].join('\n');
  }

  static String _oneLine(String value) =>
      value.trim().replaceAll(RegExp(r'\s*\n+\s*'), ' ');
}

final _osc = RegExp('\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)');
final _csi = RegExp('\x1B\\[[0-?]*[ -/]*[@-~]');
final _escape = RegExp('\x1B[@-Z\\\\-_]');

/// Terminal output as plain text: color and cursor codes removed, and a line
/// redrawn with carriage returns (progress bars) kept at its last state.
String cleanTerminalText(String text) {
  final plain = text
      .replaceAll(_osc, '')
      .replaceAll(_csi, '')
      .replaceAll(_escape, '')
      .replaceAll('\r\n', '\n');
  if (!plain.contains('\r')) return plain;
  return [
    for (final line in plain.split('\n'))
      line.split('\r').lastWhere((part) => part.isNotEmpty, orElse: () => ''),
  ].join('\n');
}

class ToolOutput {
  const ToolOutput({this.text, this.stderr});

  final String? text;
  final String? stderr;

  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) &&
      (stderr == null || stderr!.trim().isEmpty);
}
