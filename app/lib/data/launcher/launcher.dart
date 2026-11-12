// The ways into the app from the rest of the phone: text shared from
// another app, and the launcher icon's shortcuts to recent sessions.

import 'dart:async';

import 'package:app/data/hosts/hosts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Text shared from another app, waiting for the session it goes to: the
/// next one opened takes it into its composer.
class SharedDraft extends ChangeNotifier {
  String? _text;

  String? get text => _text;

  void offer(String text) {
    _text = text;
    notifyListeners();
  }

  /// The text, once: the composer that takes it now holds it.
  String? take() {
    final text = _text;
    if (text != null) clear();
    return text;
  }

  void clear() {
    if (_text == null) return;
    _text = null;
    notifyListeners();
  }
}

/// A recent session on the launcher icon's menu.
typedef SessionShortcut = ({
  String host,
  String session,
  String title,
  String subtitle,
});

abstract interface class Launcher {
  /// Text shared into the app while it runs.
  Stream<String> get shared;

  /// Text whose sharing started the app, once.
  Future<String?> takeLaunchText();

  Future<void> setShortcuts(List<SessionShortcut> sessions);
}

class MethodChannelLauncher implements Launcher {
  MethodChannelLauncher() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared' && call.arguments is String) {
        _shared.add(call.arguments as String);
      }
    });
  }

  static const _channel = MethodChannel('dev.wianger.baya/launcher');
  final _shared = StreamController<String>.broadcast();

  @override
  Stream<String> get shared => _shared.stream;

  @override
  Future<String?> takeLaunchText() async {
    try {
      return await _channel.invokeMethod<String>('launchText');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> setShortcuts(List<SessionShortcut> sessions) async {
    try {
      await _channel.invokeMethod<void>('shortcuts', [
        for (final s in sessions)
          {
            'host': s.host,
            'session': s.session,
            'title': s.title,
            'subtitle': s.subtitle,
          },
      ]);
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException catch (error) {
      debugPrint('launcher.shortcuts: $error');
    }
  }
}

/// Keeps the launcher's shortcuts on the sessions used last.
class SessionShortcuts {
  SessionShortcuts(this._hosts, this._launcher);

  final Hosts _hosts;
  final Launcher _launcher;
  static const _count = 4;
  List<SessionShortcut> _shown = const [];
  Timer? _pending;

  void start() {
    _hosts.addListener(_schedule);
    _schedule();
  }

  // Hosts change in bursts while connecting; set them once it settles.
  void _schedule() {
    _pending?.cancel();
    _pending = Timer(const Duration(seconds: 2), _update);
  }

  void _update() {
    final next = [
      for (final hosted in _hosts.sessions.take(_count))
        (
          host: hosted.hostKey,
          session: hosted.sessionId,
          title: hosted.session.title.isEmpty
              ? hosted.session.agentName
              : hosted.session.title,
          subtitle: hosted.host.host.label,
        ),
    ];
    if (listEquals(next, _shown)) return;
    _shown = next;
    unawaited(_launcher.setShortcuts(next));
  }

  void dispose() {
    _pending?.cancel();
    _hosts.removeListener(_schedule);
  }
}
