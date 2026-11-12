// The slice of ACP v1 (agentclientprotocol.com) the phone reads and writes,
// plus Baya's `_meta.baya` additions. Unknown variants parse to `Unknown…`
// values so a newer agent never breaks the app.

import 'package:app/acp/json_rpc.dart';

const protocolVersion = 1;

Json _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

List<Json> _maps(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is Map) item.cast<String, dynamic>(),
      ]
    : const [];

String? _string(Object? value) => value is String ? value : null;

/// `_meta.baya` of an ACP object.
Json bayaMeta(Json json) => _map(_map(json['_meta'])['baya']);

// ── Content ──────────────────────────────────────────────────────────────

sealed class ContentBlock {
  const ContentBlock();

  factory ContentBlock.fromJson(Json json) => switch (json['type']) {
    'text' => TextContent(_string(json['text']) ?? ''),
    'image' => ImageContent(
      data: _string(json['data']) ?? '',
      mimeType: _string(json['mimeType']) ?? 'image/png',
    ),
    'resource_link' => ResourceLinkContent(
      name: _string(json['name']) ?? '',
      uri: _string(json['uri']) ?? '',
      title: _string(json['title']),
    ),
    'resource' => ResourceContent(
      uri: _string(_map(json['resource'])['uri']) ?? '',
      text: _string(_map(json['resource'])['text']),
    ),
    _ => UnknownContent(json),
  };

  Json toJson();

  /// What a person reads for this block.
  String get displayText;
}

class TextContent extends ContentBlock {
  final String text;
  const TextContent(this.text);

  @override
  Json toJson() => {'type': 'text', 'text': text};

  @override
  String get displayText => text;
}

class ImageContent extends ContentBlock {
  /// Base64 without a data-URI prefix.
  final String data;
  final String mimeType;
  const ImageContent({required this.data, required this.mimeType});

  @override
  Json toJson() => {'type': 'image', 'data': data, 'mimeType': mimeType};

  @override
  String get displayText => '';
}

class ResourceLinkContent extends ContentBlock {
  final String name;
  final String uri;
  final String? title;
  const ResourceLinkContent({
    required this.name,
    required this.uri,
    this.title,
  });

  @override
  Json toJson() => {
    'type': 'resource_link',
    'name': name,
    'uri': uri,
    if (title != null) 'title': title,
  };

  @override
  String get displayText => '[${title ?? name}]($uri)';
}

class ResourceContent extends ContentBlock {
  final String uri;
  final String? text;
  const ResourceContent({required this.uri, this.text});

  @override
  Json toJson() => {
    'type': 'resource',
    'resource': {'uri': uri, if (text != null) 'text': text},
  };

  @override
  String get displayText => text ?? uri;
}

class UnknownContent extends ContentBlock {
  final Json raw;
  const UnknownContent(this.raw);

  @override
  Json toJson() => raw;

  @override
  String get displayText => '';
}

// ── Tool calls ───────────────────────────────────────────────────────────

enum ToolKind {
  read,
  edit,
  delete,
  move,
  search,
  execute,
  think,
  fetch,
  switchMode,
  other;

  static ToolKind? parse(Object? value) => switch (value) {
    'read' => read,
    'edit' => edit,
    'delete' => delete,
    'move' => move,
    'search' => search,
    'execute' => execute,
    'think' => think,
    'fetch' => fetch,
    'switch_mode' => switchMode,
    'other' => other,
    _ => null,
  };
}

enum ToolStatus {
  pending,
  inProgress,
  completed,
  failed;

  static ToolStatus? parse(Object? value) => switch (value) {
    'pending' => pending,
    'in_progress' => inProgress,
    'completed' => completed,
    'failed' => failed,
    _ => null,
  };

  bool get finished => this == completed || this == failed;
}

sealed class ToolCallContent {
  const ToolCallContent();

  static ToolCallContent? fromJson(Json json) => switch (json['type']) {
    'content' => ToolCallText(ContentBlock.fromJson(_map(json['content']))),
    'diff' => ToolCallDiff(
      path: _string(json['path']) ?? '',
      oldText: _string(json['oldText']),
      newText: _string(json['newText']) ?? '',
      firstLine: switch (bayaMeta(json)['firstLine']) {
        final int line when line > 0 => line,
        _ => 1,
      },
    ),
    'terminal' => ToolCallTerminal(_string(json['terminalId']) ?? ''),
    _ => null,
  };
}

class ToolCallText extends ToolCallContent {
  final ContentBlock content;
  const ToolCallText(this.content);
}

class ToolCallDiff extends ToolCallContent {
  final String path;

  /// Null for a new file.
  final String? oldText;
  final String newText;

  /// The line of the file the texts start at: the computer leaves out long
  /// unchanged runs before and after a change.
  final int firstLine;
  const ToolCallDiff({
    required this.path,
    this.oldText,
    required this.newText,
    this.firstLine = 1,
  });
}

/// A live terminal on the agent's side; Baya does not stream these.
class ToolCallTerminal extends ToolCallContent {
  final String terminalId;
  const ToolCallTerminal(this.terminalId);
}

class ToolLocation {
  final String path;
  final int? line;
  const ToolLocation(this.path, [this.line]);
}

/// `tool_call` and `tool_call_update` alike: every field but the id may be
/// absent, meaning "unchanged".
class ToolCallPatch {
  final String id;
  final String? title;
  final ToolKind? kind;
  final ToolStatus? status;
  final List<ToolCallContent>? content;
  final List<ToolLocation>? locations;
  final Object? rawInput;
  final Object? rawOutput;

  const ToolCallPatch({
    required this.id,
    this.title,
    this.kind,
    this.status,
    this.content,
    this.locations,
    this.rawInput,
    this.rawOutput,
  });

  factory ToolCallPatch.fromJson(Json json) => ToolCallPatch(
    id: _string(json['toolCallId']) ?? '',
    title: _string(json['title']),
    kind: ToolKind.parse(json['kind']),
    status: ToolStatus.parse(json['status']),
    content: json['content'] is List
        ? [
            for (final item in _maps(json['content']))
              ?ToolCallContent.fromJson(item),
          ]
        : null,
    locations: json['locations'] is List
        ? [
            for (final item in _maps(json['locations']))
              ToolLocation(
                _string(item['path']) ?? '',
                (item['line'] as num?)?.toInt(),
              ),
          ]
        : null,
    rawInput: json['rawInput'],
    rawOutput: json['rawOutput'],
  );
}

// ── Plans, commands, config ──────────────────────────────────────────────

enum PlanStatus { pending, inProgress, completed }

class PlanEntry {
  final String content;
  final PlanStatus status;
  const PlanEntry(this.content, this.status);

  factory PlanEntry.fromJson(Json json) =>
      PlanEntry(_string(json['content']) ?? '', switch (json['status']) {
        'in_progress' => PlanStatus.inProgress,
        'completed' => PlanStatus.completed,
        _ => PlanStatus.pending,
      });

  @override
  bool operator ==(Object other) =>
      other is PlanEntry && other.content == content && other.status == status;

  @override
  int get hashCode => Object.hash(content, status);
}

/// A slash command the agent offers; sent as the prompt text `/<name> …`.
class AgentCommandInfo {
  final String name;
  final String description;

  /// Placeholder for the text after the command, when it takes some.
  final String? hint;
  const AgentCommandInfo(this.name, this.description, [this.hint]);

  factory AgentCommandInfo.fromJson(Json json) => AgentCommandInfo(
    _string(json['name']) ?? '',
    _string(json['description']) ?? '',
    _string(_map(json['input'])['hint']),
  );
}

class ConfigChoice {
  final String value;
  final String name;
  final String? description;

  /// Name of the group this choice belongs to, when the agent groups them.
  final String? group;
  const ConfigChoice(this.value, this.name, {this.description, this.group});
}

/// A session setting: model, reasoning effort, mode or anything else the
/// agent exposes (`session/set_config_option`).
class ConfigOption {
  final String id;
  final String name;
  final String? description;

  /// `model`, `thought_level`, `mode`, … or null.
  final String? category;

  /// Select options carry [value] and [choices]; boolean ones [enabled].
  final String? value;
  final bool? enabled;
  final List<ConfigChoice> choices;

  const ConfigOption({
    required this.id,
    required this.name,
    this.description,
    this.category,
    this.value,
    this.enabled,
    this.choices = const [],
  });

  bool get isBoolean => enabled != null;

  ConfigChoice? get current {
    for (final choice in choices) {
      if (choice.value == value) return choice;
    }
    return null;
  }

  factory ConfigOption.fromJson(Json json) {
    final choices = <ConfigChoice>[];
    for (final item in _maps(json['options'])) {
      if (item['options'] is List) {
        final group = _string(item['name']);
        for (final option in _maps(item['options'])) {
          choices.add(
            ConfigChoice(
              _string(option['value']) ?? '',
              _string(option['name']) ?? '',
              description: _string(option['description']),
              group: group,
            ),
          );
        }
      } else {
        choices.add(
          ConfigChoice(
            _string(item['value']) ?? '',
            _string(item['name']) ?? '',
            description: _string(item['description']),
          ),
        );
      }
    }
    final current = json['currentValue'];
    return ConfigOption(
      id: _string(json['id']) ?? '',
      name: _string(json['name']) ?? '',
      description: _string(json['description']),
      category: _string(json['category']),
      value: current is String ? current : null,
      enabled: json['type'] == 'boolean' ? current == true : null,
      choices: choices,
    );
  }

  static List<ConfigOption> listFrom(Object? value) => [
    for (final item in _maps(value)) ConfigOption.fromJson(item),
  ];
}

class SessionMode {
  final String id;
  final String name;
  final String? description;
  const SessionMode(this.id, this.name, [this.description]);
}

class SessionModes {
  final String currentModeId;
  final List<SessionMode> available;
  const SessionModes(this.currentModeId, this.available);

  static SessionModes? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<String, dynamic>();
    return SessionModes(_string(json['currentModeId']) ?? '', [
      for (final mode in _maps(json['availableModes']))
        SessionMode(
          _string(mode['id']) ?? '',
          _string(mode['name']) ?? '',
          _string(mode['description']),
        ),
    ]);
  }

  SessionModes withCurrent(String id) => SessionModes(id, available);
}

/// How full the agent's context window is.
class Usage {
  final int used;
  final int size;
  final double? cost;
  final String? currency;
  const Usage(this.used, this.size, {this.cost, this.currency});

  double get fraction => size <= 0 ? 0 : (used / size).clamp(0, 1).toDouble();
}

// ── session/update ───────────────────────────────────────────────────────

enum ChunkRole { user, agent, thought }

sealed class SessionUpdate {
  const SessionUpdate();

  factory SessionUpdate.fromJson(Json json) {
    switch (json['sessionUpdate']) {
      case 'user_message_chunk':
      case 'agent_message_chunk':
      case 'agent_thought_chunk':
        return MessageChunk(
          switch (json['sessionUpdate']) {
            'user_message_chunk' => ChunkRole.user,
            'agent_thought_chunk' => ChunkRole.thought,
            _ => ChunkRole.agent,
          },
          ContentBlock.fromJson(_map(json['content'])),
          _string(json['messageId']),
          startup: bayaMeta(json)['startup'] == true,
        );
      case 'tool_call':
        return ToolCallUpdate(ToolCallPatch.fromJson(json), isNew: true);
      case 'tool_call_update':
        return ToolCallUpdate(ToolCallPatch.fromJson(json), isNew: false);
      case 'plan':
        return PlanUpdate([
          for (final entry in _maps(json['entries'])) PlanEntry.fromJson(entry),
        ]);
      case 'available_commands_update':
        return CommandsUpdate([
          for (final command in _maps(json['availableCommands']))
            AgentCommandInfo.fromJson(command),
        ]);
      case 'current_mode_update':
        return ModeUpdate(_string(json['currentModeId']) ?? '');
      case 'config_option_update':
        return ConfigUpdate(ConfigOption.listFrom(json['configOptions']));
      case 'session_info_update':
        return SessionInfoChanged(_string(json['title']));
      case 'usage_update':
        final cost = _map(json['cost']);
        return UsageUpdate(
          Usage(
            (json['used'] as num?)?.toInt() ?? 0,
            (json['size'] as num?)?.toInt() ?? 0,
            cost: (cost['amount'] as num?)?.toDouble(),
            currency: _string(cost['currency']),
          ),
        );
      case 'notice':
        return NoticeUpdate(
          _string(json['severity']) ?? 'info',
          _string(json['title']) ?? '',
          _string(bayaMeta(json)['authRequired']),
        );
      case 'compaction_update':
        final summary = _maps(json['summary'])
            .map(ContentBlock.fromJson)
            .map((block) => block.displayText)
            .join();
        return CompactionUpdate(
          _string(json['compactionId']) ?? '',
          _string(json['status']) ?? 'in_progress',
          summary.isEmpty ? null : summary,
        );
      case 'compaction_summary_chunk':
        return CompactionSummaryChunk(
          _string(json['compactionId']) ?? '',
          ContentBlock.fromJson(_map(json['content'])).displayText,
        );
      default:
        return const UnknownUpdate();
    }
  }
}

class MessageChunk extends SessionUpdate {
  final ChunkRole role;
  final ContentBlock content;
  final String? messageId;

  /// The agent said it on its own before the first prompt (Baya marks it).
  final bool startup;
  const MessageChunk(
    this.role,
    this.content,
    this.messageId, {
    this.startup = false,
  });
}

class ToolCallUpdate extends SessionUpdate {
  final ToolCallPatch patch;
  final bool isNew;
  const ToolCallUpdate(this.patch, {required this.isNew});
}

class PlanUpdate extends SessionUpdate {
  final List<PlanEntry> entries;
  const PlanUpdate(this.entries);
}

class CommandsUpdate extends SessionUpdate {
  final List<AgentCommandInfo> commands;
  const CommandsUpdate(this.commands);
}

class ModeUpdate extends SessionUpdate {
  final String modeId;
  const ModeUpdate(this.modeId);
}

class ConfigUpdate extends SessionUpdate {
  final List<ConfigOption> options;
  const ConfigUpdate(this.options);
}

class SessionInfoChanged extends SessionUpdate {
  final String? title;
  const SessionInfoChanged(this.title);
}

class UsageUpdate extends SessionUpdate {
  final Usage usage;
  const UsageUpdate(this.usage);
}

class NoticeUpdate extends SessionUpdate {
  final String severity;
  final String title;

  /// The agent that needs a sign-in, when that is what the notice is about.
  final String? authAgent;
  const NoticeUpdate(this.severity, this.title, [this.authAgent]);
}

class CompactionUpdate extends SessionUpdate {
  final String id;
  final String status;
  final String? summary;
  const CompactionUpdate(this.id, this.status, this.summary);
}

class CompactionSummaryChunk extends SessionUpdate {
  final String id;
  final String text;
  const CompactionSummaryChunk(this.id, this.text);
}

class UnknownUpdate extends SessionUpdate {
  const UnknownUpdate();
}

// ── Permissions ──────────────────────────────────────────────────────────

enum PermissionKind { allowOnce, allowAlways, rejectOnce, rejectAlways }

class PermissionOption {
  final String id;
  final String name;
  final PermissionKind kind;
  const PermissionOption(this.id, this.name, this.kind);

  bool get allows =>
      kind == PermissionKind.allowOnce || kind == PermissionKind.allowAlways;
}

/// `session/request_permission`: the agent waits for one of [options].
class PermissionRequest {
  /// JSON-RPC id of the request, matched by `$/cancel_request`.
  final Object requestId;
  final String sessionId;
  final ToolCallPatch toolCall;
  final List<PermissionOption> options;

  const PermissionRequest({
    required this.requestId,
    required this.sessionId,
    required this.toolCall,
    required this.options,
  });

  factory PermissionRequest.fromJson(Object requestId, Json json) =>
      PermissionRequest(
        requestId: requestId,
        sessionId: _string(json['sessionId']) ?? '',
        toolCall: ToolCallPatch.fromJson(_map(json['toolCall'])),
        options: [
          for (final option in _maps(json['options']))
            PermissionOption(
              _string(option['optionId']) ?? '',
              _string(option['name']) ?? '',
              switch (option['kind']) {
                'allow_always' => PermissionKind.allowAlways,
                'reject_once' => PermissionKind.rejectOnce,
                'reject_always' => PermissionKind.rejectAlways,
                _ => PermissionKind.allowOnce,
              },
            ),
        ],
      );
}

// ── Baya: computers and their sessions ───────────────────────────────────

/// An agent set up on a computer (`baya agents`).
class AgentInfo {
  final String id;
  final String name;
  final bool available;
  const AgentInfo(this.id, this.name, {this.available = true});

  @override
  bool operator ==(Object other) =>
      other is AgentInfo &&
      other.id == id &&
      other.name == name &&
      other.available == available;

  @override
  int get hashCode => Object.hash(id, name, available);
}

/// What `initialize` tells the phone about the computer.
class HostIntro {
  final String hostname;
  final String version;
  final List<AgentInfo> agents;
  const HostIntro({
    required this.hostname,
    required this.version,
    required this.agents,
  });

  factory HostIntro.fromJson(Json json) {
    final baya = bayaMeta(json);
    return HostIntro(
      hostname: _string(baya['hostname']) ?? '',
      version: _string(_map(json['agentInfo'])['version']) ?? '',
      agents: [
        for (final agent in _maps(baya['agents']))
          AgentInfo(
            _string(agent['id']) ?? '',
            _string(agent['name']) ?? '',
            available: agent['available'] != false,
          ),
      ],
    );
  }
}

/// One session on a computer (ACP `SessionInfo` with Baya's meta).
class SessionSummary {
  final String sessionId;
  final String cwd;
  final String title;
  final DateTime? updatedAt;
  final String agent;
  final String agentName;

  /// A turn is running right now.
  final bool working;

  /// The agent process is up.
  final bool running;

  /// Why the agent could not start, when it could not.
  final String? error;

  const SessionSummary({
    required this.sessionId,
    required this.cwd,
    required this.title,
    required this.agent,
    required this.agentName,
    this.updatedAt,
    this.working = false,
    this.running = false,
    this.error,
  });

  factory SessionSummary.fromJson(Json json) {
    final baya = bayaMeta(json);
    final cwd = _string(json['cwd']) ?? '';
    final agent = _string(baya['agent']) ?? '';
    return SessionSummary(
      sessionId: _string(json['sessionId']) ?? '',
      cwd: cwd,
      title: _string(json['title']) ?? folderName(cwd),
      updatedAt: DateTime.tryParse(_string(json['updatedAt']) ?? ''),
      agent: agent,
      agentName: _string(baya['agentName']) ?? agent,
      working: baya['working'] == true,
      running: baya['running'] == true,
      error: _string(baya['error']),
    );
  }

  Json toJson() => {
    'sessionId': sessionId,
    'cwd': cwd,
    'title': title,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    '_meta': {
      'baya': {
        'agent': agent,
        'agentName': agentName,
        'working': working,
        'running': running,
        if (error != null) 'error': error,
      },
    },
  };

  SessionSummary copyWith({String? title, bool? working, bool? running}) =>
      SessionSummary(
        sessionId: sessionId,
        cwd: cwd,
        title: title ?? this.title,
        updatedAt: updatedAt,
        agent: agent,
        agentName: agentName,
        working: working ?? this.working,
        running: running ?? this.running,
        error: error,
      );

  @override
  bool operator ==(Object other) =>
      other is SessionSummary &&
      other.sessionId == sessionId &&
      other.cwd == cwd &&
      other.title == title &&
      other.updatedAt == updatedAt &&
      other.agent == agent &&
      other.agentName == agentName &&
      other.working == working &&
      other.running == running &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    sessionId,
    cwd,
    title,
    updatedAt,
    agent,
    agentName,
    working,
    running,
    error,
  );
}

/// The last path segment of a folder, for either separator.
String folderName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// What `session/new`, `session/load` and `session/resume` return.
class SessionSetup {
  final List<ConfigOption> configOptions;
  final SessionModes? modes;
  final String agentName;
  final bool acceptsImages;
  final bool working;

  /// The agent can branch the conversation from an earlier reply.
  final bool canFork;

  const SessionSetup({
    this.configOptions = const [],
    this.modes,
    this.agentName = '',
    this.acceptsImages = false,
    this.working = false,
    this.canFork = false,
  });

  factory SessionSetup.fromJson(Json json) {
    final baya = bayaMeta(json);
    return SessionSetup(
      configOptions: ConfigOption.listFrom(json['configOptions']),
      modes: SessionModes.fromJson(json['modes']),
      agentName: _string(baya['agentName']) ?? '',
      acceptsImages: _map(baya['promptCapabilities'])['image'] == true,
      working: baya['working'] == true,
      canFork: baya['canFork'] == true,
    );
  }
}

// ── Terminals, elicitation, sign-in ──────────────────────────────────────

/// A terminal an agent runs on the computer (`_baya/terminal`).
class TerminalSnapshot {
  final String terminalId;
  final String output;
  final bool truncated;

  /// Null while it runs.
  final int? exitCode;
  final String? signal;
  final bool exited;

  const TerminalSnapshot({
    required this.terminalId,
    required this.output,
    this.truncated = false,
    this.exitCode,
    this.signal,
    this.exited = false,
  });

  factory TerminalSnapshot.fromJson(Json json) {
    final exit = json['exitStatus'];
    final status = exit is Map ? exit.cast<String, dynamic>() : null;
    return TerminalSnapshot(
      terminalId: _string(json['terminalId']) ?? '',
      output: _string(json['output']) ?? '',
      truncated: json['truncated'] == true,
      exitCode: (status?['exitCode'] as num?)?.toInt(),
      signal: _string(status?['signal']),
      exited: status != null,
    );
  }
}

enum ElicitationFieldType {
  text,
  number,
  integer,
  boolean,
  choice,
  multiChoice,
}

/// One field of an elicitation form (a JSON Schema property).
class ElicitationField {
  final String name;
  final String title;
  final ElicitationFieldType type;
  final bool required;
  final Object? defaultValue;

  /// For choices: value → label.
  final List<(String, String)> options;

  /// `email`, `uri`, `date`, `date-time` for text fields.
  final String? format;

  const ElicitationField({
    required this.name,
    required this.title,
    required this.type,
    this.required = false,
    this.defaultValue,
    this.options = const [],
    this.format,
  });
}

/// `elicitation/create`: the agent asks the user for structured input or to
/// open a link.
class ElicitationRequest {
  final Object requestId;
  final String? sessionId;
  final String message;

  /// Link mode: open [url]; the agent says when it is done.
  final String? url;
  final String? elicitationId;
  final String? title;
  final List<ElicitationField> fields;

  const ElicitationRequest({
    required this.requestId,
    required this.message,
    this.sessionId,
    this.url,
    this.elicitationId,
    this.title,
    this.fields = const [],
  });

  bool get isLink => url != null;

  factory ElicitationRequest.fromJson(Object requestId, Json json) {
    final schema = _map(json['requestedSchema']);
    final required = {
      for (final name in (schema['required'] as List? ?? const [])) '$name',
    };
    final fields = <ElicitationField>[];
    for (final MapEntry(:key, :value) in _map(schema['properties']).entries) {
      final property = _map(value);
      final options = <(String, String)>[
        for (final option in _maps(property['oneOf']))
          (_string(option['const']) ?? '', _string(option['title']) ?? ''),
        for (final value in (property['enum'] as List? ?? const []))
          ('$value', '$value'),
      ];
      final items = _map(property['items']);
      final itemOptions = <(String, String)>[
        for (final option in _maps(items['anyOf'] ?? items['oneOf']))
          (_string(option['const']) ?? '', _string(option['title']) ?? ''),
        for (final value in (items['enum'] as List? ?? const []))
          ('$value', '$value'),
      ];
      final type = switch (property['type']) {
        'number' => ElicitationFieldType.number,
        'integer' => ElicitationFieldType.integer,
        'boolean' => ElicitationFieldType.boolean,
        'array' => ElicitationFieldType.multiChoice,
        _ when options.isNotEmpty => ElicitationFieldType.choice,
        _ => ElicitationFieldType.text,
      };
      fields.add(
        ElicitationField(
          name: key,
          title: _string(property['title']) ?? key,
          type: type,
          required: required.contains(key),
          defaultValue: property['default'],
          options: type == ElicitationFieldType.multiChoice
              ? itemOptions
              : options,
          format: _string(property['format']),
        ),
      );
    }
    return ElicitationRequest(
      requestId: requestId,
      sessionId: _string(json['sessionId']),
      message: _string(json['message']) ?? '',
      url: json['mode'] == 'url' ? _string(json['url']) : null,
      elicitationId: _string(json['elicitationId']),
      title: _string(schema['title']),
      fields: fields,
    );
  }
}

/// How an agent signs in.
class AuthMethod {
  final String id;
  final String name;
  final String? description;

  /// Terminal sign-in: run the agent with `args` on the computer.
  final List<String>? terminalArgs;

  const AuthMethod(this.id, this.name, {this.description, this.terminalArgs});

  bool get needsComputer => terminalArgs != null;

  factory AuthMethod.fromJson(Json json) => AuthMethod(
    _string(json['id']) ?? '',
    _string(json['name']) ?? '',
    description: _string(json['description']),
    terminalArgs: json['type'] == 'terminal'
        ? [for (final arg in (json['args'] as List? ?? const [])) '$arg']
        : null,
  );
}

/// One of an agent's own conversations, not yet in Baya.
class AgentSessionInfo {
  final String sessionId;
  final String title;
  final DateTime? updatedAt;
  const AgentSessionInfo(this.sessionId, this.title, [this.updatedAt]);

  factory AgentSessionInfo.fromJson(Json json) => AgentSessionInfo(
    _string(json['sessionId']) ?? '',
    _string(json['title']) ?? '',
    DateTime.tryParse(_string(json['updatedAt']) ?? ''),
  );
}
