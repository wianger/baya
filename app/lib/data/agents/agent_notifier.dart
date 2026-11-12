// The phone's notifications about agents at work: one live notification
// (an Android 16 Live Update in the status bar) while any agent works, and
// an alert when one finishes or asks for an answer while the app is away.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A button on a notification; [payload] comes back through
/// [AgentNotifier.actions] when it is tapped.
@immutable
class NotificationAction {
  const NotificationAction(this.label, this.payload);
  final String label;
  final String payload;

  Map<String, Object?> toMap() => {'label': label, 'payload': payload};
}

/// The session a notification opens.
typedef SessionRef = ({String host, String session});

/// What the live notification shows.
@immutable
class LiveActivity {
  const LiveActivity({
    required this.title,
    required this.text,
    this.chip,
    this.since,
    this.busy = true,
    this.opens,
    this.actions = const [],
  });

  final String title;
  final String text;

  /// The status bar chip's text; without one it counts up from [since].
  final String? chip;
  final DateTime? since;

  /// An agent is at work (an indeterminate bar), rather than waiting.
  final bool busy;
  final SessionRef? opens;
  final List<NotificationAction> actions;

  Map<String, Object?> toMap() => {
    'title': title,
    'text': text,
    'chip': chip,
    'since': since?.millisecondsSinceEpoch,
    'busy': busy,
    'host': opens?.host,
    'session': opens?.session,
    'actions': [for (final a in actions) a.toMap()],
  };
}

/// A tapped notification button: its payload, and for a reply the text.
typedef TappedAction = ({String payload, String? text});

/// A reply box on a notification, as a messaging app's.
@immutable
class NotificationReply {
  const NotificationReply(this.label, this.hint, this.payload);
  final String label;
  final String hint;
  final String payload;

  Map<String, Object?> toMap() => {
    'label': label,
    'hint': hint,
    'payload': payload,
  };
}

/// A notification that asks for attention, replacing any with its [id].
@immutable
class AgentAlert {
  const AgentAlert({
    required this.id,
    required this.title,
    required this.text,
    required this.opens,
    this.actions = const [],
    this.reply,
  });

  final String id;
  final String title;
  final String text;
  final SessionRef opens;
  final List<NotificationAction> actions;
  final NotificationReply? reply;

  Map<String, Object?> toMap() => {
    'reply': reply?.toMap(),
    'id': id,
    'title': title,
    'text': text,
    'host': opens.host,
    'session': opens.session,
    'actions': [for (final a in actions) a.toMap()],
  };
}

abstract interface class AgentNotifier {
  /// Shows [activity] as the live notification; null removes it.
  Future<void> live(LiveActivity? activity);

  Future<void> alert(AgentAlert alert);

  Future<void> cancel(String id);

  /// Asks to post notifications. Unless [settings], only the first time;
  /// with it, opens Android's settings when the dialog can't be shown.
  Future<void> ask({bool settings = false});

  /// Whether Android lets the app post notifications.
  Future<bool> allowed();

  /// Tapped notification buttons and sent replies.
  Stream<TappedAction> get actions;

  /// Sessions whose notification was tapped.
  Stream<SessionRef> get opened;

  /// The session whose notification started the app, once.
  Future<SessionRef?> takeLaunch();
}

class MethodChannelAgentNotifier implements AgentNotifier {
  MethodChannelAgentNotifier() {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      switch (call.method) {
        case 'action':
          if (args case {'payload': final String payload}) {
            _actions.add((
              payload: payload,
              text: args['text'] is String ? args['text'] as String : null,
            ));
          }
        case 'open':
          final ref = _ref(args);
          if (ref != null) _opened.add(ref);
      }
    });
  }

  static const _channel = MethodChannel('dev.wianger.baya/agents');
  final _actions = StreamController<TappedAction>.broadcast();
  final _opened = StreamController<SessionRef>.broadcast();

  static SessionRef? _ref(Object? args) => switch (args) {
    {'host': final String host, 'session': final String session} => (
      host: host,
      session: session,
    ),
    _ => null,
  };

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException catch (error) {
      debugPrint('agents.$method: $error');
    }
  }

  @override
  Future<void> live(LiveActivity? activity) => _call('live', activity?.toMap());

  @override
  Future<void> alert(AgentAlert alert) => _call('alert', alert.toMap());

  @override
  Future<void> cancel(String id) => _call('cancel', id);

  @override
  Future<void> ask({bool settings = false}) =>
      _call('ask', {'settings': settings});

  @override
  Future<bool> allowed() async {
    try {
      return await _channel.invokeMethod<bool>('allowed') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Stream<TappedAction> get actions => _actions.stream;

  @override
  Stream<SessionRef> get opened => _opened.stream;

  @override
  Future<SessionRef?> takeLaunch() async {
    try {
      return _ref(await _channel.invokeMethod<Object?>('launch'));
    } on MissingPluginException {
      return null;
    }
  }
}
