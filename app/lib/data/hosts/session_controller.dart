// One open conversation: loads it from the computer (`session/load` replays
// the history), keeps it current from `session/update`, and sends prompts,
// cancels, setting changes and permission answers.

import 'dart:async';
import 'dart:convert';

import 'package:app/acp/acp.dart';
import 'package:app/acp/json_rpc.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/transfer/file_transfer.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/transcript.dart';
import 'package:app/protocol/uuid7.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

class SessionController extends ChangeNotifier {
  SessionController(this.host, this.sessionId) {
    _updates = host.updates.listen(_onUpdate);
    _questions = host.questions.listen((_) => _syncPermissions());
    _terminals = host.terminals.listen((event) {
      if (event.sessionId != sessionId) return;
      if (_held case final held?) return held.add(event);
      _seen(event.seq);
      _transcript.terminal(event.snapshot);
      if (!_loading) _changed();
    });
    _online = host.onOnline.listen((_) => unawaited(_load()));
    host.addListener(_onHostChanged);
    _restore();
    _syncPermissions();
    unawaited(_load());
  }

  final HostConnection host;
  final String sessionId;

  late final Transcript _transcript;
  late final StreamSubscription<SessionEvent> _updates;
  late final StreamSubscription<QuestionEvent> _questions;
  late final StreamSubscription<TerminalEvent> _terminals;
  late final StreamSubscription<void> _online;

  bool _loading = false;
  bool _loaded = false;

  /// What arrives while a load is out, applied once its answer says whether
  /// it is a catch-up (on top of what is here) or the whole history.
  List<Object>? _held;

  /// Where this phone is in the session's live notifications, so coming
  /// back (screen on, new network) fetches only what it missed.
  String? _epoch;
  int _seq = 0;
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

  final _drafts = StreamController<UserMsg>.broadcast();

  /// Sent messages to put back in the composer, to edit and send again.
  Stream<UserMsg> get drafts => _drafts.stream;

  void editAgain(UserMsg message) {
    if (!_drafts.isClosed) _drafts.add(message);
  }

  /// Messages waiting for the composer of a branch that is opening.
  static final _handoff = <String, UserMsg>{};

  /// Conversations left most recently, newest last, with where each was in
  /// its live notifications: opening one again shows it at once and only
  /// catches up, instead of replaying it.
  static final _kept = <String, _Kept>{};
  static const _keep = 6;

  void _restore() {
    final kept = _kept.remove('${host.key}/$sessionId');
    if (kept == null) {
      _transcript = Transcript();
      return;
    }
    _transcript = kept.transcript;
    _epoch = kept.epoch;
    _seq = kept.seq;
    _setup = kept.setup;
    _config = kept.config;
    _modes = kept.modes;
    _commands = kept.commands;
    _usage = kept.usage;
    _loaded = true;
  }

  void _keepForLater() {
    final epoch = _epoch;
    if (!_loaded || epoch == null || _error != null) return;
    final key = '${host.key}/$sessionId';
    _kept.remove(key);
    _kept[key] = _Kept(
      transcript: _transcript,
      epoch: epoch,
      seq: _seq,
      setup: _setup,
      config: _config,
      modes: _modes,
      commands: _commands,
      usage: _usage,
    );
    while (_kept.length > _keep) {
      _kept.remove(_kept.keys.first);
    }
  }

  /// Forgets kept conversations (tests start clean).
  @visibleForTesting
  static void forgetKept() => _kept.clear();

  bool get canFork => _setup.canFork;

  /// A new session on this computer with this conversation up to the reply
  /// before [message], which waits in its composer. Returns its id.
  Future<String> branchBefore(UserMsg message) async {
    final result = await host.call('_baya/fork', {
      'sessionId': sessionId,
      ...?forkPoint(messages, message),
    }, const Duration(minutes: 2));
    final id = (result['session'] as Map)['sessionId'] as String;
    _handoff['${host.key}/$id'] = message;
    return id;
  }

  /// Where a branch before [message] ends: the agent's last reply before
  /// it, by id and, for agents that lost the id, by its text's SHA-256 and
  /// which match of that text it is. Null before the first reply.
  static Json? forkPoint(List<ChatMessage> messages, UserMsg message) {
    final at = messages.indexWhere((m) => m.id == message.id);
    final replies = messages
        .take(at < 0 ? 0 : at)
        .whereType<AssistantMsg>()
        .where((m) => !m.startup)
        .toList();
    if (replies.isEmpty) return null;
    String fingerprint(String text) {
      final digest = Sha256().toSync().hashSync(utf8.encode(text)).bytes;
      return 'sha256:${digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    }

    final last = replies.last;
    final target = fingerprint(last.text);
    var occurrence = 0;
    for (final reply in replies) {
      if (fingerprint(reply.text) == target) occurrence++;
    }
    return {
      'messageId': last.id,
      'messageFingerprint': target,
      'messageOccurrence': occurrence,
    };
  }

  /// Files between the phone and this session's folder.
  FileTransfer get transfer => FileTransfer(HostTransferLink(host, sessionId));

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

  // Reviewing the agent's work in the session's git repository.

  Future<Map<String, dynamic>> gitStatus() =>
      host.call('_baya/git_status', {'sessionId': sessionId});

  Future<Map<String, dynamic>> gitDiff(String path) =>
      host.call('_baya/git_diff', {'sessionId': sessionId, 'path': path});

  /// Undoes one hunk of [path], or the whole file when [hunk] is null.
  Future<Map<String, dynamic>> gitRevert(String path, {int? hunk}) => host.call(
    '_baya/git_revert',
    {'sessionId': sessionId, 'path': path, 'hunk': ?hunk},
  );

  Future<Map<String, dynamic>> gitCommit(String message) => host.call(
    '_baya/git_commit',
    {'sessionId': sessionId, 'message': message},
    const Duration(minutes: 1),
  );

  Future<Map<String, dynamic>> gitPush() => host.call('_baya/git_push', {
    'sessionId': sessionId,
  }, const Duration(minutes: 2));

  Future<Map<String, dynamic>> openPullRequest(String title, String body) =>
      host.call('_baya/pr_create', {
        'sessionId': sessionId,
        'title': title,
        'body': body,
      }, const Duration(minutes: 2));

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
    final resume = _loaded && _epoch != null
        ? {'epoch': _epoch, 'seq': _seq}
        : null;
    _loading = true;
    _error = null;
    _changed();
    // A first load shows the history as it streams in. A catch-up holds
    // what comes until the answer says it is one, or the whole history.
    final held = <Object>[];
    if (resume != null) {
      _held = held;
    } else {
      _transcript.clear();
    }
    var replaced = false;
    try {
      final result = await host.call('session/load', {
        'sessionId': sessionId,
        'cwd': summary?.cwd ?? '',
        'mcpServers': const <Object>[],
        if (resume != null)
          '_meta': {
            'baya': {'resume': resume},
          },
      }, const Duration(minutes: 3));
      final meta = bayaMeta(result);
      replaced = resume != null && meta['resumed'] != true;
      final cursor = meta['cursor'];
      if (cursor is Map && cursor['epoch'] is String && cursor['seq'] is int) {
        _epoch = cursor['epoch'] as String;
        _seq = cursor['seq'] as int;
      } else {
        _epoch = null;
      }
      _setup = SessionSetup.fromJson(result);
      _config = _setup.configOptions;
      _modes = _setup.modes;
      _loaded = true;
      final waiting = _handoff.remove('${host.key}/$sessionId');
      if (waiting != null) scheduleMicrotask(() => editAgain(waiting));
    } catch (error) {
      _error = _describe(error);
      // A failed catch-up keeps what is shown.
      held.clear();
    } finally {
      _held = null;
      if (replaced) _transcript.clear();
      for (final event in held) {
        switch (event) {
          case SessionEvent():
            _apply(event);
          case TerminalEvent(:final snapshot, :final seq):
            _seen(seq);
            _transcript.terminal(snapshot);
        }
      }
      _loading = false;
      if (summary?.working != true) _transcript.settle();
      _changed();
    }
  }

  void _seen(int? seq) {
    if (seq != null && seq > _seq) _seq = seq;
  }

  void _onUpdate(SessionEvent event) {
    if (event.sessionId != sessionId) return;
    if (_held case final held?) return held.add(event);
    _apply(event);
    // A replay is drawn once, when it is done.
    if (!_loading) _changed();
  }

  void _apply(SessionEvent event) {
    _seen(event.seq);
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
  }

  void _onHostChanged() {
    // Offline, nothing is known to have finished: a catch-up may continue it.
    if (host.isOnline && summary?.working == false && !_localWorking) {
      _transcript.settle();
    }
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

  /// At most one rebuild per frame: the first change shows at once, and
  /// what streams in during the next 16 ms follows in one more.
  void _changed() {
    if (_disposed) return;
    if (_throttle != null) {
      _changedSince = true;
      return;
    }
    notifyListeners();
    _throttle = Timer(const Duration(milliseconds: 16), () {
      _throttle = null;
      if (_changedSince) {
        _changedSince = false;
        _changed();
      }
    });
  }

  Timer? _throttle;
  bool _changedSince = false;

  static String _describe(Object error) => switch (error) {
    RpcError(:final message) => message,
    RpcClosed(:final reason) => reason,
    TimeoutException() => 'The computer did not answer in time.',
    _ => '$error',
  };

  @override
  void dispose() {
    _keepForLater();
    _disposed = true;
    _handoff.remove('${host.key}/$sessionId');
    _throttle?.cancel();
    unawaited(_drafts.close());
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

class _Kept {
  _Kept({
    required this.transcript,
    required this.epoch,
    required this.seq,
    required this.setup,
    required this.config,
    required this.modes,
    required this.commands,
    required this.usage,
  });

  final Transcript transcript;
  final String epoch;
  final int seq;
  final SessionSetup setup;
  final List<ConfigOption> config;
  final SessionModes? modes;
  final List<AgentCommandInfo> commands;
  final Usage? usage;
}
