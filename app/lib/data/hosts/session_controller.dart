// One open conversation: loads it from the computer (`session/load` replays
// the history), keeps it current from `session/update`, and sends prompts,
// cancels, setting changes and permission answers.

import 'dart:async';

import 'package:app/acp/acp.dart';
import 'package:app/acp/json_rpc.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/transcript.dart';
import 'package:app/protocol/uuid7.dart';
import 'package:flutter/foundation.dart';

class SessionController extends ChangeNotifier {
  SessionController(this.host, this.sessionId) {
    _updates = host.updates.listen(_onUpdate);
    _questions = host.questions.listen((_) => _syncPermissions());
    _terminals = host.terminals.listen((event) {
      if (event.sessionId != sessionId) return;
      _transcript.terminal(event.snapshot);
      if (!_replaying) _changed();
    });
    _online = host.onOnline.listen((_) => unawaited(_load()));
    host.addListener(_onHostChanged);
    _syncPermissions();
    unawaited(_load());
  }

  final HostConnection host;
  final String sessionId;

  final _transcript = Transcript();
  late final StreamSubscription<SessionEvent> _updates;
  late final StreamSubscription<QuestionEvent> _questions;
  late final StreamSubscription<TerminalEvent> _terminals;
  late final StreamSubscription<void> _online;

  bool _loading = false;
  bool _loaded = false;
  bool _replaying = false;
  bool _disposed = false;
  String? _error;
  bool _localWorking = false;
  SessionSetup _setup = const SessionSetup();
  List<ConfigOption> _config = const [];
  SessionModes? _modes;
  List<AgentCommandInfo> _commands = const [];
  Usage? _usage;
  List<PermissionRequest> _openPermissions = const [];
  List<ElicitationRequest> _openElicitations = const [];
  List<ResourceLinkContent> _files = const [];
  String? _authAgent;

  // ── state ───────────────────────────────────────────────────────────────

  List<ChatMessage> get messages => _transcript.messages;
  SessionSummary? get summary => host.session(sessionId);
  String get title => summary?.title ?? '';
  String get agentName =>
      _setup.agentName.isNotEmpty ? _setup.agentName : summary?.agentName ?? '';
  bool get online => host.isOnline;

  /// The history arrived from the computer at least once.
  bool get loaded => _loaded;
  bool get loading => _loading;

  /// Why the session could not open, when it could not.
  String? get error => _error;

  /// A turn is running: the computer says so, or this phone just sent one.
  bool get working => online && (_localWorking || summary?.working == true);

  List<ConfigOption> get configOptions => _config;
  ConfigOption? configFor(String category) =>
      _config.where((option) => option.category == category).firstOrNull;
  SessionModes? get modes => _modes;
  List<AgentCommandInfo> get commands => _commands;
  Usage? get usage => _usage;
  bool get acceptsImages => _setup.acceptsImages;

  /// The oldest open permission question for this session.
  PermissionRequest? get permission => _openPermissions.firstOrNull;

  /// The oldest open elicitation (form or link) for this session.
  ElicitationRequest? get elicitation => _openElicitations.firstOrNull;

  /// Files from the computer to send with the next prompt.
  List<ResourceLinkContent> get attachedFiles => _files;

  void attachFile(String path, String name) {
    // The computer may run Windows whatever the phone runs.
    final windows = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
    final uri = Uri.file(path, windows: windows).toString();
    if (_files.any((f) => f.uri == uri)) return;
    _files = [..._files, ResourceLinkContent(name: name, uri: uri)];
    _changed();
  }

  void removeFile(ResourceLinkContent file) {
    _files = _files.where((f) => f.uri != file.uri).toList();
    _changed();
  }

  /// Lists a folder of the session's computer (for attaching files).
  Future<Map<String, dynamic>> browseFiles([String? path]) =>
      host.call('_baya/files', {'sessionId': sessionId, 'path': ?path});

  /// The agent that last asked to be signed in, until it works again.
  String? get authAgent => _authAgent;

  // ── commands ────────────────────────────────────────────────────────────

  /// Sends a prompt; the agent queues it behind a running turn. [files]
  /// are links to files on the computer the agent can open.
  Future<void> prompt(
    String text, {
    MessageImage? image,
    List<ResourceLinkContent> files = const [],
  }) async {
    final id = uuid7();
    if (files.isEmpty && _files.isNotEmpty) {
      files = _files;
      _files = const [];
    }
    _transcript.addPending(
      UserMsg(id: id, text: text, status: UserMsgStatus.pending, image: image),
    );
    _localWorking = true;
    _changed();
    try {
      final result = await host.call('session/prompt', {
        'sessionId': sessionId,
        'prompt': [
          if (text.isNotEmpty) TextContent(text).toJson(),
          if (image != null)
            ImageContent(data: image.data, mimeType: image.mime).toJson(),
          for (final file in files) file.toJson(),
        ],
        '_meta': {
          'baya': {'messageId': id},
        },
      }, Duration.zero);
      _authAgent = null;
      if (result['stopReason'] == 'refusal') {
        _transcript.apply(const NoticeUpdate('warning', 'The agent refused.'));
      }
    } catch (error) {
      _transcript.dropPending(id);
      if (error is RpcError && error.reason == 'auth_required') {
        _authAgent =
            (error.data as Map?)?['agent'] as String? ?? summary?.agent;
      }
      // A turn that failed on the computer already left a notice there.
      final reported =
          error is RpcError && error.code != RpcError.invalidParams;
      if (!reported) _transcript.apply(NoticeUpdate('error', _describe(error)));
    } finally {
      _localWorking = false;
      _transcript.settle();
      _changed();
    }
  }

  void cancel() {
    host.notify('session/cancel', {'sessionId': sessionId});
  }

  Future<void> setConfig(String configId, Object value) async {
    final result = await host.call('session/set_config_option', {
      'sessionId': sessionId,
      'configId': configId,
      if (value is bool) 'type': 'boolean',
      'value': value,
    });
    _config = ConfigOption.listFrom(result['configOptions']);
    _changed();
  }

  Future<void> setMode(String modeId) async {
    await host.call('session/set_mode', {
      'sessionId': sessionId,
      'modeId': modeId,
    });
    _modes = _modes?.withCurrent(modeId);
    _changed();
  }

  void answerElicitation(String action, [Map<String, dynamic>? content]) {
    final open = elicitation;
    if (open == null) return;
    host.answerElicitation(open.requestId, action, content);
    _syncPermissions();
  }

  /// How the session's agent signs in.
  Future<(List<AuthMethod>, bool)> authMethods() async {
    final result = await host.call('_baya/agent_auth', {
      'agent': _authAgent ?? summary?.agent,
    }, const Duration(minutes: 2));
    return (
      [
        for (final method in (result['authMethods'] as List? ?? const []))
          if (method is Map)
            AuthMethod.fromJson(method.cast<String, dynamic>()),
      ],
      result['logout'] == true,
    );
  }

  /// Signs the agent in with [methodId]; the next prompt uses it.
  Future<void> authenticate(String methodId) async {
    await host.call('_baya/authenticate', {
      'agent': _authAgent ?? summary?.agent,
      'methodId': methodId,
    }, const Duration(minutes: 5));
    _authAgent = null;
    _changed();
  }

  /// Signs the agent out on the computer; every session with it needs a
  /// new sign-in, which the sign-in card offers.
  Future<void> logout() async {
    final agent = _authAgent ?? summary?.agent;
    await host.call('_baya/logout', {
      'agent': agent,
    }, const Duration(minutes: 2));
    _authAgent = agent;
    _changed();
  }

  void answerPermission(String? optionId) {
    final open = permission;
    if (open == null) return;
    host.answerPermission(open.requestId, optionId);
    _syncPermissions();
  }

  /// Reload after an error.
  Future<void> retry() => _load();

  // ── loading ─────────────────────────────────────────────────────────────

  Future<void> _load() async {
    if (_disposed || _loading || !host.isOnline) {
      _changed();
      return;
    }
    _loading = true;
    _error = null;
    _changed();
    // The replay rebuilds the history from scratch.
    _transcript.clear();
    _replaying = true;
    try {
      final result = await host.call('session/load', {
        'sessionId': sessionId,
        'cwd': summary?.cwd ?? '',
        'mcpServers': const <Object>[],
      }, const Duration(minutes: 3));
      _setup = SessionSetup.fromJson(result);
      _config = _setup.configOptions;
      _modes = _setup.modes;
      _loaded = true;
    } catch (error) {
      _error = _describe(error);
    } finally {
      _replaying = false;
      _loading = false;
      if (summary?.working != true) _transcript.settle();
      _changed();
    }
  }

  void _onUpdate(SessionEvent event) {
    if (event.sessionId != sessionId) return;
    final update = event.update;
    switch (update) {
      case ConfigUpdate(:final options):
        _config = options;
      case ModeUpdate(:final modeId):
        _modes = _modes?.withCurrent(modeId);
      case CommandsUpdate(:final commands):
        _commands = commands;
      case UsageUpdate(:final usage):
        _usage = usage;
      default:
        _transcript.apply(update);
    }
    if (!_replaying) _changed();
  }

  void _onHostChanged() {
    if (summary?.working == false && !_localWorking) _transcript.settle();
    _changed();
  }

  void _syncPermissions() {
    _openPermissions = [
      for (final request in host.openPermissions)
        if (request.sessionId == sessionId) request,
    ];
    _openElicitations = [
      for (final request in host.openElicitations)
        if (request.sessionId == null || request.sessionId == sessionId)
          request,
    ];
    _transcript.markAwaiting({
      for (final request in _openPermissions) request.toolCall.id,
    });
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  static String _describe(Object error) => switch (error) {
    RpcError(:final message) => message,
    RpcClosed(:final reason) => reason,
    TimeoutException() => 'The computer did not answer in time.',
    _ => '$error',
  };

  @override
  void dispose() {
    _disposed = true;
    unawaited(_updates.cancel());
    unawaited(_questions.cancel());
    unawaited(_terminals.cancel());
    unawaited(_online.cancel());
    host.removeListener(_onHostChanged);
    // Stop receiving this session's updates; harmless if offline.
    if (host.isOnline) {
      unawaited(
        host
            .call('session/close', {'sessionId': sessionId})
            .then((_) {}, onError: (_) {}),
      );
    }
    super.dispose();
  }
}
