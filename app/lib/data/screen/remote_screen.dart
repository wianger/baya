// Remote control of a computer through Moonlight's streaming core, embedded
// in this app (android/app/src/main/{java/com/limelight,jni}): the computer
// runs Sunshine, Baya's host there completes the pairing, and the stream —
// hardware H.264/HEVC/AV1 over RTP with FEC, decoded by MediaCodec in
// low-latency mode — lands in a Flutter texture. Touches and keys go back
// as Moonlight input.
import 'dart:async';
import 'dart:math';

import 'package:app/data/hosts/host_connection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// How the picture trades sharpness and smoothness for data.
enum ScreenQuality { best, balanced, saver }

enum ScreenState { connecting, live, ended }

/// The native Moonlight bridge, as an interface for tests.
abstract class MoonlightBridge {
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]);
  Stream<Map<Object?, Object?>> get events;
}

class ChannelMoonlight implements MoonlightBridge {
  static const _methods = MethodChannel('dev.wianger.baya/moonlight');
  static const _events = EventChannel('dev.wianger.baya/moonlight/events');
  static final _stream = _events
      .receiveBroadcastStream()
      .cast<Map<Object?, Object?>>();

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? arguments]) =>
      _methods.invokeMethod<Object?>(method, arguments);

  @override
  Stream<Map<Object?, Object?>> get events => _stream;
}

/// The stream's size, rate and bitrate (kbit/s) for [quality] on a phone
/// whose screen refreshes at [refresh] Hz.
({int width, int height, int fps, int bitrate}) streamFor(
  ScreenQuality quality,
  double refresh,
) {
  final fast = refresh >= 100 ? 120 : 60;
  return switch (quality) {
    // As sharp and smooth as the phone shows: 1440p at its refresh rate.
    ScreenQuality.best => (
      width: 2560,
      height: 1440,
      fps: fast,
      bitrate: fast == 120 ? 80000 : 50000,
    ),
    ScreenQuality.balanced => (
      width: 1920,
      height: 1080,
      fps: 60,
      bitrate: 20000,
    ),
    ScreenQuality.saver => (width: 1280, height: 720, fps: 30, bitrate: 5000),
  };
}

/// Windows virtual-key codes by the names the keys send.
const _virtualKeys = <String, int>{
  'backspace': 0x08,
  'tab': 0x09,
  'enter': 0x0d,
  'shift': 0xa0,
  'ctrl': 0xa2,
  'alt': 0xa4,
  'escape': 0x1b,
  'space': 0x20,
  'pageup': 0x21,
  'pagedown': 0x22,
  'end': 0x23,
  'home': 0x24,
  'left': 0x25,
  'up': 0x26,
  'right': 0x27,
  'down': 0x28,
  'delete': 0x2e,
  'win': 0x5b,
};

int? _virtualKey(String name) {
  final known = _virtualKeys[name];
  if (known != null) return known;
  if (RegExp(r'^[a-z]$').hasMatch(name)) {
    return name.toUpperCase().codeUnitAt(0);
  }
  if (RegExp(r'^[0-9]$').hasMatch(name)) return name.codeUnitAt(0);
  final f = RegExp(r'^f([1-9]|1[0-2])$').firstMatch(name);
  if (f != null) {
    return 0x6f + int.parse(f.group(1)!);
  }
  return null;
}

const _modifierBits = {'shift': 0x01, 'ctrl': 0x02, 'alt': 0x04, 'win': 0x08};

/// One remote-control session with one computer.
class RemoteScreenSession extends ChangeNotifier {
  RemoteScreenSession(
    this._host, {
    MoonlightBridge? bridge,
    FlutterSecureStorage? storage,
    this.deviceName = 'Baya',
  }) : _bridge = bridge ?? ChannelMoonlight(),
       _storage = storage ?? const FlutterSecureStorage();

  final HostConnection _host;

  @visibleForTesting
  HostConnection get hostForTest => _host;
  final MoonlightBridge _bridge;
  final FlutterSecureStorage _storage;
  final String deviceName;
  StreamSubscription<Map<Object?, Object?>>? _events;
  bool _disposed = false;

  ScreenState state = ScreenState.connecting;

  /// What it is doing while connecting (pairing, a Moonlight stage).
  String? stage;

  /// Why it ended, or why it would not start.
  String? reason;

  /// The texture the stream draws into, once started.
  int? texture;

  /// The stream's size: the computer's screen as it arrives.
  Size? screenSize;

  /// Moonlight's own numbers (decoder, rates, latency), refreshed as it goes.
  String? stats;

  /// The link is poor right now (Moonlight says so).
  bool poor = false;

  String get _certKey => 'moonlight.cert.${_host.key}';

  Future<void> start({
    ScreenQuality quality = ScreenQuality.best,
    double refresh = 60,
  }) async {
    _events = _bridge.events.listen(_event);
    try {
      final info = await _host.call('_baya/screen_info');
      final address = info['address'] as String?;
      if (info['ready'] != true || address == null) {
        throw StateError(
          info['reason'] as String? ?? 'This computer cannot be controlled.',
        );
      }
      var cert = await _storage.read(key: _certKey);
      final paired =
          cert != null &&
          await _bridge.invoke('paired', {'address': address, 'cert': cert}) ==
              true;
      if (!paired) cert = await _pair(address);
      final stream = streamFor(quality, refresh);
      _set(stage: 'stream');
      final started = await _bridge.invoke('start', {
        'address': address,
        'cert': cert,
        'width': stream.width,
        'height': stream.height,
        'fps': stream.fps,
        'bitrate': stream.bitrate,
      });
      texture = (started! as Map)['texture'] as int;
      screenSize = Size(stream.width.toDouble(), stream.height.toDouble());
      _notify();
    } catch (error) {
      _end(switch (error) {
        PlatformException(:final message, :final code) => message ?? code,
        StateError(:final message) => message,
        _ => '$error',
      });
    }
  }

  /// Pairs this phone with Sunshine: the phone makes up a PIN and asks to
  /// pair; Baya on the computer hands Sunshine the same PIN.
  Future<String> _pair(String address) async {
    _set(stage: 'pair');
    final pin = Random.secure().nextInt(10000).toString().padLeft(4, '0');
    final pairing = _bridge.invoke('pair', {'address': address, 'pin': pin});
    final told = _host.call('_baya/screen_pair', {
      'pin': pin,
      'name': deviceName,
    }, const Duration(seconds: 30));
    final result = await pairing as Map;
    await told.catchError((_) => <String, dynamic>{});
    final cert = result['cert'] as String?;
    if (result['state'] != 'PAIRED' || cert == null) {
      throw StateError('Pairing with Sunshine failed (${result['state']}).');
    }
    await _storage.write(key: _certKey, value: cert);
    return cert;
  }

  void _event(Map<Object?, Object?> event) {
    switch (event['event']) {
      case 'stage':
        _set(stage: event['stage'] as String?);
      case 'started':
        state = ScreenState.live;
        _notify();
      case 'failed':
        _end(
          '${event['stage']} failed (${event['code']}) ${event['ports'] ?? ''}',
        );
      case 'ended':
        _end(event['code'] == 0 ? 'ended' : 'error ${event['code']}');
      case 'status':
        poor = event['poor'] == true;
        _notify();
      case 'stats':
        stats = event['text'] as String?;
        _notify();
      case 'message':
        reason = event['text'] as String?;
        _notify();
    }
  }

  void _set({String? stage}) {
    this.stage = stage;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _end(String why) {
    if (state == ScreenState.ended) return;
    state = ScreenState.ended;
    reason ??= why;
    _notify();
  }

  // ── input ──────────────────────────────────────────────────────────────

  void _invoke(String method, Map<String, Object?> arguments) {
    if (state != ScreenState.live) return;
    unawaited(_bridge.invoke(method, arguments).catchError((_) => null));
  }

  /// Input as the gestures and keys build it: fractions of the screen for
  /// the pointer, names for keys.
  void input(Map<String, Object?> message) {
    final size = screenSize;
    if (size == null) return;
    final w = size.width.round();
    final h = size.height.round();
    if (message['r'] case [final num dx, final num dy]) {
      _invoke('mouseMove', {'dx': (dx * w).round(), 'dy': (dy * h).round()});
    }
    if (message['m'] case [final num x, final num y]) {
      _invoke('mousePosition', {
        'x': (x * w).round(),
        'y': (y * h).round(),
        'width': w,
        'height': h,
      });
    }
    if (message['b'] case final String name) {
      final button = switch (name) {
        'r' => 3,
        'm' => 2,
        _ => 1,
      };
      final clicks = message['n'];
      if (clicks is int && clicks > 0) {
        for (var i = 0; i < clicks; i++) {
          _invoke('button', {'button': button, 'down': true});
          _invoke('button', {'button': button, 'down': false});
        }
      } else {
        _invoke('button', {'button': button, 'down': message['d'] == true});
      }
    }
    if (message['w'] case [final num dy, final num dx]) {
      if (dy != 0) _invoke('scroll', {'amount': (dy * 120).round()});
      if (dx != 0) {
        _invoke('scroll', {'amount': (dx * 120).round(), 'horizontal': true});
      }
    }
    if (message['k'] case final String name) {
      final key = _virtualKey(name.toLowerCase());
      final mods = [
        for (final m in (message['mods'] as List? ?? const []))
          if (m is String && _virtualKey(m) != null) m,
      ];
      if (key != null) {
        var bits = 0;
        for (final m in mods) {
          bits |= _modifierBits[m] ?? 0;
          _key(_virtualKey(m)!, down: true, modifiers: bits);
        }
        _key(key, down: true, modifiers: bits);
        _key(key, down: false, modifiers: bits);
        for (final m in mods.reversed) {
          bits &= ~(_modifierBits[m] ?? 0);
          _key(_virtualKey(m)!, down: false, modifiers: bits);
        }
      }
    }
    if (message['t'] case final String text when text.isNotEmpty) {
      _invoke('text', {'text': text});
    }
  }

  void _key(int vk, {required bool down, required int modifiers}) =>
      _invoke('key', {
        // Moonlight's key map: 0x80 marks a Windows virtual-key code.
        'code': 0x8000 | vk,
        'down': down,
        'modifiers': modifiers,
      });

  Future<void> stop() async {
    _end('stopped');
    await _events?.cancel();
    await _bridge.invoke('stop').catchError((_) => null);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
