// Turns what the paired computers report into the phone's notifications:
// the live one while agents work, and alerts when one finishes or asks for
// an answer while the app is in the background.

import 'dart:async';
import 'dart:convert';

import 'package:app/acp/acp.dart';
import 'package:app/data/agents/agent_notifier.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/l10n/l10n.dart';

class AgentWatch {
  AgentWatch(
    this._hosts,
    this._prefs,
    this._notifier, {
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Hosts _hosts;
  final Preferences _prefs;
  final AgentNotifier _notifier;
  final DateTime Function() _now;
  final _subscriptions = <StreamSubscription<Object?>>[];

  bool _foreground = true;

  /// When each working session's turn was first seen, by [_key].
  final _since = <String, DateTime>{};

  /// Alerts posted and not yet withdrawn.
  final _alerts = <String>{};

  String? _shown;
  bool _asked = false;

  void start() {
    _hosts.addListener(_update);
    _prefs.addListener(_update);
    _subscriptions.add(_notifier.actions.listen(_act));
    _update();
  }

  /// The app came to the front or went away. In front, its own screens say
  /// what the questions would.
  set foreground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (value) {
      for (final id in _alerts.where((id) => id.startsWith('ask:')).toList()) {
        _withdraw(id);
      }
    }
    _update();
  }

  static String _key(HostConnection host, String sessionId) =>
      '${host.key}|$sessionId';

  void _update() {
    final enabled = _prefs.notifyAgents;
    final working = <(HostConnection, SessionSummary)>[];
    final questions = <String, AgentAlert>{};
    final hosts = _hosts.all;

    for (final host in hosts) {
      // Until the computer has listed its sessions again, a turn that looks
      // over may only be one this phone has not heard about.
      if (!host.isOnline || !host.sessionsLive) continue;
      for (final session in host.sessions) {
        final key = _key(host, session.sessionId);
        if (session.working) {
          working.add((host, session));
          if (!_since.containsKey(key)) {
            _since[key] = _now();
            _withdraw('done:$key');
          }
        } else if (_since.remove(key) != null && enabled && !_foreground) {
          _post(_finished(host, session));
        } else if (!_prefs.isUnread(host.key, session)) {
          // Read in the app since: the notification has said its piece.
          _withdraw('done:$key');
        }
      }
      // An agent stopped for an answer in its pane on the computer.
      for (final session in host.sessions) {
        if (!session.waitingForAnswer) continue;
        final alert = _question(host, session);
        questions[alert.id] = alert;
      }
    }
    // Computers no longer paired take their turns with them.
    final known = {for (final host in hosts) host.key};
    _since.removeWhere((key, _) => !known.contains(key.split('|').first));

    for (final id in _alerts.where((id) => id.startsWith('ask:')).toList()) {
      if (!enabled || !questions.containsKey(id)) _withdraw(id);
    }
    if (enabled && !_foreground) {
      for (final alert in questions.values) {
        if (!_alerts.contains(alert.id)) _post(alert);
      }
    }
    if (!enabled) {
      for (final id in _alerts.toList()) {
        _withdraw(id);
      }
    }

    _showLive(
      enabled && (working.isNotEmpty || questions.isNotEmpty)
          ? _live(working, questions.values.toList())
          : null,
    );
  }

  LiveActivity _live(
    List<(HostConnection, SessionSummary)> working,
    List<AgentAlert> questions,
  ) {
    final l10n = appL10n;
    final starts = [
      for (final (host, session) in working)
        ?_since[_key(host, session.sessionId)],
    ]..sort();
    final waiting = questions.isNotEmpty;
    if (working.length == 1) {
      final (host, session) = working.single;
      final ref = (host: host.key, session: session.sessionId);
      return LiveActivity(
        title: _title(session),
        text: waiting
            ? l10n.waitingForYouCount(questions.length)
            : l10n.agentOn(_agent(session), host.host.label),
        chip: waiting ? l10n.approveChip : null,
        since: starts.firstOrNull,
        busy: !waiting,
        opens: waiting ? questions.first.opens : ref,
        actions: [
          if (!waiting) NotificationAction(l10n.notifyStop, _stop(ref)),
        ],
      );
    }
    return LiveActivity(
      title: working.isEmpty
          ? l10n.waitingForYouCount(questions.length)
          : l10n.agentsAtWork(working.length),
      text: waiting && working.isNotEmpty
          ? l10n.waitingForYouCount(questions.length)
          : [for (final (_, s) in working) _title(s)].join(' · '),
      chip: waiting ? l10n.approveChip : null,
      since: starts.firstOrNull,
      busy: !waiting,
      opens: waiting
          ? questions.first.opens
          : (host: working.first.$1.key, session: working.first.$2.sessionId),
    );
  }

  AgentAlert _finished(HostConnection host, SessionSummary session) =>
      AgentAlert(
        id: 'done:${_key(host, session.sessionId)}',
        title: _title(session),
        text: appL10n.agentFinishedOn(_agent(session), host.host.label),
        opens: (host: host.key, session: session.sessionId),
        // The next prompt, without opening the app.
        reply: NotificationReply(
          appL10n.notifyReply,
          appL10n.replyTo(_agent(session)),
          jsonEncode({
            'reply': {'host': host.key, 'session': session.sessionId},
          }),
        ),
      );

  AgentAlert _question(HostConnection host, SessionSummary session) =>
      AgentAlert(
        id: 'ask:${host.key}|${session.sessionId}',
        title: appL10n.agentHasQuestion(_agent(session)),
        text: _title(session),
        opens: (host: host.key, session: session.sessionId),
      );

  static String _agent(SessionSummary session) =>
      session.agentName.isEmpty ? session.agent : session.agentName;

  static String _title(SessionSummary session) =>
      session.title.isEmpty ? _agent(session) : session.title;

  static String _stop(SessionRef ref) => jsonEncode({
    'stop': {'host': ref.host, 'session': ref.session},
  });

  void _showLive(LiveActivity? activity) {
    final shown = activity == null ? null : jsonEncode(activity.toMap());
    if (shown == _shown) return;
    final first = _shown == null;
    _shown = shown;
    unawaited(_notifier.live(activity));
    // Asked once, when there is first something to show.
    if (activity != null && first && _foreground && !_asked) {
      _asked = true;
      unawaited(_notifier.ask());
    }
  }

  void _post(AgentAlert alert) {
    _alerts.add(alert.id);
    unawaited(_notifier.alert(alert));
  }

  void _withdraw(String id) {
    if (_alerts.remove(id)) unawaited(_notifier.cancel(id));
  }

  /// A notification button was tapped, or a reply sent.
  void _act(TappedAction tapped) {
    final Object? message;
    try {
      message = jsonDecode(tapped.payload);
    } on FormatException {
      return;
    }
    switch (message) {
      case {'stop': {'host': final String host, 'session': final String id}}:
        _hosts.byKey(host)?.notify('session/cancel', {'sessionId': id});
      case {'reply': {'host': final String host, 'session': final String id}}:
        if (tapped.text case final text?) unawaited(_reply(host, id, text));
    }
  }

  /// Sends [text] as the session's next prompt. The turn it starts shows
  /// live like any other; one that can't be sent says so.
  Future<void> _reply(String hostKey, String sessionId, String text) async {
    final host = _hosts.byKey(hostKey);
    if (host == null || !host.isOnline) {
      return _post(
        AgentAlert(
          id: 'unsent:$hostKey|$sessionId',
          title: appL10n.replyNotSent,
          text: text,
          opens: (host: hostKey, session: sessionId),
        ),
      );
    }
    try {
      // Answers when the turn ends, however long that is.
      await host.call('session/prompt', {
        'sessionId': sessionId,
        'prompt': [
          {'type': 'text', 'text': text},
        ],
      }, Duration.zero);
    } on Object {
      // Sent: how the turn went shows in the session.
    }
  }

  void dispose() {
    _hosts.removeListener(_update);
    _prefs.removeListener(_update);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_notifier.live(null));
  }
}
