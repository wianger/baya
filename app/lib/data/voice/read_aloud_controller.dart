import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Coordinates the platform text-to-speech engine so only one assistant
/// message is read at a time. The Android implementation lives in
/// `MainActivity`; keeping the channel in-app avoids a third-party Gradle
/// plugin that is incompatible with the project's AGP 9 built-in Kotlin.
class ReadAloudController extends ChangeNotifier {
  ReadAloudController._() {
    _channel.setMethodCallHandler(_handlePlatformCall);
  }

  static final ReadAloudController instance = ReadAloudController._();

  static const _channel = MethodChannel('dev.wianger.remotepi/read_aloud');

  Object? _owner;
  bool _speaking = false;

  bool isSpeakingFor(Object owner) => _speaking && identical(_owner, owner);

  Future<void> toggle({
    required Object owner,
    required String text,
    required String language,
  }) async {
    if (isSpeakingFor(owner)) {
      await stopFor(owner);
    } else {
      await speak(owner: owner, text: text, language: language);
    }
  }

  Future<void> speak({
    required Object owner,
    required String text,
    required String language,
  }) async {
    if (text.isEmpty) return;
    if (_speaking) await _stopNative();
    try {
      final started = await _channel.invokeMethod<bool>('speak', {
        'text': text,
        'language': language,
      });
      _owner = started == true ? owner : null;
      _setSpeaking(started == true);
    } on MissingPluginException {
      _setSpeaking(false);
    } on PlatformException {
      _setSpeaking(false);
    }
  }

  Future<void> stopFor(Object owner) async {
    if (!identical(_owner, owner)) return;
    await stop();
  }

  Future<void> stop() async {
    _owner = null;
    _setSpeaking(false);
    await _stopNative();
  }

  Future<void> _stopNative() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // The channel is absent in widget tests and on unsupported platforms.
    } on PlatformException {
      // Stop is best-effort; the UI state has already settled.
    }
  }

  Future<Object?> _handlePlatformCall(MethodCall call) async {
    if (call.method == 'completed') _setSpeaking(false);
    return null;
  }

  void _setSpeaking(bool value) {
    if (_speaking == value) return;
    _speaking = value;
    if (!value) _owner = null;
    notifyListeners();
  }
}
