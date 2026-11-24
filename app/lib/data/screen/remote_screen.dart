// Remote control of a computer: its screen as a WebRTC video track, and
// this phone's touches and keys back over a data channel. Signalling rides
// the encrypted link to the host (`_baya/screen_*`); media and input go
// straight over the tailnet, DTLS-SRTP end to end, decoded in hardware.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Size;

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// How the picture trades sharpness for smoothness and data.
enum ScreenQuality { smooth, balanced, saver }

enum ScreenState { connecting, live, ended }

/// One remote-control session with one computer.
class RemoteScreenSession extends ChangeNotifier {
  RemoteScreenSession(this._host);

  final HostConnection _host;
  final renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  RTCDataChannel? _input;
  String? _screenId;
  StreamSubscription<Json>? _ended;
  Timer? _ping;
  bool _disposed = false;

  ScreenState state = ScreenState.connecting;

  /// Why it ended, or why it would not start.
  String? reason;

  /// The encoder on the computer (`h264_nvenc` …), for the info line.
  String? encoder;

  /// Round trip of the input channel, in milliseconds.
  int? rtt;

  /// The computer's screen in pixels, once known.
  Size? screenSize;

  Future<void> start({ScreenQuality quality = ScreenQuality.balanced}) async {
    await renderer.initialize();
    renderer.onResize = notifyListeners;
    _ended = _host.screenEnded.listen((params) {
      if (params['screenId'] == _screenId) {
        _end(params['reason'] as String? ?? 'ended');
      }
    });
    try {
      final offer = await _host.call('_baya/screen_start', {
        'quality': quality.name,
      }, const Duration(seconds: 40));
      _screenId = offer['screenId'] as String;
      encoder = offer['encoder'] as String?;
      final width = offer['width'];
      final height = offer['height'];
      if (width is num && height is num) {
        screenSize = Size(width.toDouble(), height.toDouble());
      }
      // The tailnet connects the two directly: no STUN, no TURN.
      final pc = await createPeerConnection({
        'iceServers': <Object>[],
        'sdpSemantics': 'unified-plan',
      });
      _pc = pc;
      pc.onTrack = (event) {
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          renderer.srcObject = event.streams.first;
        }
      };
      pc.onDataChannel = (channel) {
        _input = channel;
        channel.onMessage = _message;
        _ping = Timer.periodic(const Duration(seconds: 2), (_) {
          _send({'ping': DateTime.now().millisecondsSinceEpoch});
        });
      };
      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        _host.notify('_baya/screen_candidate', {
          'screenId': _screenId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      };
      pc.onConnectionState = (connection) {
        switch (connection) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            state = ScreenState.live;
            notifyListeners();
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _end('failed');
          default:
        }
      };
      await pc.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String, 'offer'),
      );
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await _host.call('_baya/screen_answer', {
        'screenId': _screenId,
        'sdp': answer.sdp,
      });
    } catch (error) {
      reason = '$error';
      _end(reason!);
    }
  }

  void _message(RTCDataChannelMessage message) {
    if (message.isBinary) return;
    try {
      final data = jsonDecode(message.text);
      if (data case {'pong': final int sent}) {
        rtt = DateTime.now().millisecondsSinceEpoch - sent;
        notifyListeners();
      }
    } on FormatException {
      // Not for us.
    }
  }

  void _send(Map<String, Object?> message) {
    final channel = _input;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    unawaited(channel.send(RTCDataChannelMessage(jsonEncode(message))));
  }

  /// Input for the computer, as the gestures and keys build it.
  void input(Map<String, Object?> message) => _send(message);

  void _end(String why) {
    if (state == ScreenState.ended) return;
    state = ScreenState.ended;
    reason ??= why;
    _ping?.cancel();
    if (!_disposed) notifyListeners();
  }

  /// Ends the session on the computer and here.
  Future<void> stop() async {
    _ping?.cancel();
    final id = _screenId;
    if (id != null && _host.isOnline && state != ScreenState.ended) {
      unawaited(
        _host
            .call('_baya/screen_stop', {'screenId': id})
            .then((_) {}, onError: (_) {}),
      );
    }
    _end('stopped');
    await _ended?.cancel();
    await _input?.close();
    await _pc?.close();
    renderer.srcObject = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop().whenComplete(renderer.dispose));
    super.dispose();
  }
}
