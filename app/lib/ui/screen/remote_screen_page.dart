/// A computer's screen, full screen on the phone, to use with touch: as a
/// touchpad or by pointing, pinch to zoom in on small text, a keyboard with
/// the keys a desktop needs. Turn the phone for landscape.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:app/data/screen/remote_screen.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/screen/screen_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class RemoteScreenPage extends StatefulWidget {
  const RemoteScreenPage({
    super.key,
    required this.label,
    required this.connect,
  });

  /// The computer's name.
  final String label;

  /// A new session with the computer, not yet started.
  final RemoteScreenSession Function() connect;

  @override
  State<RemoteScreenPage> createState() => _RemoteScreenPageState();
}

/// A blank kept in the hidden field, so a backspace has something to delete.
const _blank = '​';

class _RemoteScreenPageState extends State<RemoteScreenPage> {
  late RemoteScreenSession _session = widget.connect();
  late final ScreenGestures _gestures = ScreenGestures(
    send: (message) => _session.input(message),
    toScreen: _toScreen,
    pictureSize: () => _picture.size,
    onZoom: _zoom,
  );
  final _typing = TextEditingController(text: _blank);
  final _typingFocus = FocusNode();
  ScreenQuality _quality = ScreenQuality.best;
  bool _keyboard = false;
  bool _ctrl = false;
  bool _alt = false;
  bool _shift = false;

  /// The picture at zoom 1 (fitted, letterboxed), and how the user zoomed.
  Rect _fitted = Rect.zero;
  double _scale = 1;
  Offset _pan = Offset.zero;

  Rect get _picture => Rect.fromLTWH(
    _fitted.left * _scale + _pan.dx,
    _fitted.top * _scale + _pan.dy,
    _fitted.width * _scale,
    _fitted.height * _scale,
  );

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(_session.start(quality: _quality, refresh: _refresh));
    _session.addListener(_changed);
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _session.dispose();
    _gestures.dispose();
    _typing.dispose();
    _typingFocus.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Offset? _toScreen(Offset local) {
    final picture = _picture;
    if (picture.isEmpty) return null;
    final x = (local.dx - picture.left) / picture.width;
    final y = (local.dy - picture.top) / picture.height;
    if (x < 0 || y < 0 || x > 1 || y > 1) return null;
    return Offset(x, y);
  }

  void _zoom(double scale, Offset focal, Offset pan) {
    setState(() {
      final next = (_scale * scale).clamp(1.0, 5.0);
      final applied = next / _scale;
      // Keep the point under the fingers under them.
      _pan = focal - (focal - _pan) * applied + pan;
      _scale = next;
      if (_scale == 1) _pan = Offset.zero;
      _clampPan();
    });
  }

  void _clampPan() {
    final size = _viewport;
    if (size == null) return;
    final width = size.width * _scale;
    final height = size.height * _scale;
    _pan = Offset(
      _pan.dx.clamp(size.width - width, 0),
      _pan.dy.clamp(size.height - height, 0),
    );
  }

  Size? _viewport;

  void _layout(Size viewport) {
    _viewport = viewport;
    final video = _videoSize;
    if (video == null) {
      _fitted = Rect.zero;
      return;
    }
    final fit = math.min(
      viewport.width / video.width,
      viewport.height / video.height,
    );
    final size = Size(video.width * fit, video.height * fit);
    _fitted = Rect.fromLTWH(
      (viewport.width - size.width) / 2,
      (viewport.height - size.height) / 2,
      size.width,
      size.height,
    );
  }

  Size? get _videoSize => _session.screenSize;

  /// The phone screen's refresh rate: the stream runs as fast as it shows.
  double get _refresh {
    try {
      return WidgetsBinding
          .instance
          .platformDispatcher
          .displays
          .first
          .refreshRate;
    } catch (_) {
      return 60;
    }
  }

  // ── keyboard ───────────────────────────────────────────────────────────

  void _toggleKeyboard() {
    unawaited(HapticFeedback.selectionClick());
    setState(() => _keyboard = !_keyboard);
    if (_keyboard) {
      _typingFocus.requestFocus();
    } else {
      _typingFocus.unfocus();
    }
  }

  List<String> get _mods => [
    if (_ctrl) 'ctrl',
    if (_alt) 'alt',
    if (_shift) 'shift',
  ];

  void _clearMods() {
    if (_ctrl || _alt || _shift) {
      setState(() => _ctrl = _alt = _shift = false);
    }
  }

  void _key(String key, {List<String> mods = const []}) {
    unawaited(HapticFeedback.selectionClick());
    _session.input({
      'k': key,
      'mods': [...mods, ..._mods],
    });
    _clearMods();
  }

  /// The hidden field changed: what was added is typed, a blank that went
  /// missing is a backspace. With a modifier held, a letter is a shortcut.
  void _typed(String value) {
    if (!value.startsWith(_blank)) {
      _key('backspace');
    } else {
      final text = value.substring(_blank.length);
      if (text.isNotEmpty) {
        final lower = text.toLowerCase();
        if (_mods.isNotEmpty &&
            text.length == 1 &&
            RegExp(r'^[a-z0-9]$').hasMatch(lower)) {
          _key(lower);
        } else {
          _session.input({'t': text});
        }
      }
    }
    _typing.value = const TextEditingValue(
      text: _blank,
      selection: TextSelection.collapsed(offset: _blank.length),
    );
  }

  /// Starts over at [quality]: the computer encodes for it from the start.
  void _requality(ScreenQuality quality) {
    if (quality == _quality) return;
    _session
      ..removeListener(_changed)
      ..dispose();
    setState(() {
      _quality = quality;
      _session = widget.connect()..addListener(_changed);
    });
    unawaited(_session.start(quality: quality, refresh: _refresh));
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _layout(constraints.biggest);
                final picture = _picture;
                return Listener(
                  key: const Key('remote-screen-surface'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _gestures.down,
                  onPointerMove: _gestures.move,
                  onPointerUp: _gestures.up,
                  onPointerCancel: _gestures.up,
                  child: Stack(
                    children: [
                      if (!picture.isEmpty)
                        Positioned.fromRect(
                          rect: picture,
                          child: session.texture == null
                              ? const SizedBox.shrink()
                              : Texture(
                                  textureId: session.texture!,
                                  filterQuality: FilterQuality.medium,
                                ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          // Typing goes through a field nobody sees.
          Positioned(
            left: 0,
            bottom: 0,
            width: 1,
            height: 1,
            child: Opacity(
              opacity: 0,
              child: TextField(
                key: const Key('remote-screen-typing'),
                controller: _typing,
                focusNode: _typingFocus,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                onChanged: _typed,
                onSubmitted: (_) {
                  _key('enter');
                  _typingFocus.requestFocus();
                },
              ),
            ),
          ),
          if (session.state != ScreenState.live)
            Positioned.fill(
              child: _Status(
                label: widget.label,
                session: session,
                onBack: () => Navigator.of(context).maybePop(),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _Toolbar(
                  label: widget.label,
                  session: session,
                  mode: _gestures.mode,
                  keyboard: _keyboard,
                  quality: _quality,
                  zoomed: _scale > 1,
                  onMode: () {
                    unawaited(HapticFeedback.selectionClick());
                    setState(() {
                      _gestures.mode = _gestures.mode == PointerMode.touchpad
                          ? PointerMode.direct
                          : PointerMode.touchpad;
                    });
                  },
                  onKeyboard: _toggleKeyboard,
                  onQuality: _requality,
                  onFit: () => setState(() {
                    _scale = 1;
                    _pan = Offset.zero;
                  }),
                  onClose: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
          if (_keyboard)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Keys(
                ctrl: _ctrl,
                alt: _alt,
                shift: _shift,
                onCtrl: () => setState(() => _ctrl = !_ctrl),
                onAlt: () => setState(() => _alt = !_alt),
                onShift: () => setState(() => _shift = !_shift),
                onKey: _key,
              ),
            ),
        ],
      ),
    );
  }
}

/// Connecting, or why it ended, over a dark screen.
class _Status extends StatelessWidget {
  const _Status({
    required this.label,
    required this.session,
    required this.onBack,
  });

  final String label;
  final RemoteScreenSession session;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ended = session.state == ScreenState.ended;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ended)
                const Icon(
                  LucideIcons.monitorOff,
                  color: Colors.white70,
                  size: 30,
                )
              else
                const SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: Colors.white,
                  ),
                ),
              const SizedBox(height: 18),
              Text(
                ended
                    ? l10n.remoteControlEnded
                    : l10n.remoteControlConnecting(label),
                key: const Key('remote-screen-status'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: BayaType.callout,
                ),
              ),
              if (!ended && session.stage == 'pair') ...[
                const SizedBox(height: 8),
                Text(
                  l10n.remoteControlPairing,
                  key: const Key('remote-screen-pairing'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: BayaType.footnote,
                  ),
                ),
              ],
              if (ended && session.reason != null) ...[
                const SizedBox(height: 8),
                Text(
                  switch (session.reason) {
                    'not_installed' => l10n.remoteControlNotInstalled,
                    'not_running' => l10n.remoteControlNotRunning,
                    'foreign_account' => l10n.remoteControlForeignAccount,
                    'not_windows' => l10n.remoteControlNotWindows,
                    final other => other!,
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: BayaType.footnote,
                  ),
                ),
              ],
              if (ended) ...[
                const SizedBox(height: 18),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                  ),
                  onPressed: onBack,
                  child: Text(l10n.close),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small floating bar: pointer mode, keyboard, quality, fit, close, and
/// how fast the link is.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.label,
    required this.session,
    required this.mode,
    required this.keyboard,
    required this.quality,
    required this.zoomed,
    required this.onMode,
    required this.onKeyboard,
    required this.onQuality,
    required this.onFit,
    required this.onClose,
  });

  final String label;
  final RemoteScreenSession session;
  final PointerMode mode;
  final bool keyboard;
  final ScreenQuality quality;
  final bool zoomed;
  final VoidCallback onMode;
  final VoidCallback onKeyboard;
  final ValueChanged<ScreenQuality> onQuality;
  final VoidCallback onFit;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget button(
      IconData icon,
      String tooltip,
      VoidCallback onTap, {
      bool on = false,
      Key? key,
    }) => IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onTap,
      style: IconButton.styleFrom(
        backgroundColor: on ? Colors.white : Colors.transparent,
        foregroundColor: on ? Colors.black : Colors.white,
        minimumSize: const Size(40, 40),
      ),
      icon: Icon(icon, size: 20),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: Colors.black.withValues(alpha: .62),
        shape: StadiumBorder(
          side: BorderSide(color: Colors.white.withValues(alpha: .14)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button(
              LucideIcons.x,
              l10n.close,
              onClose,
              key: const Key('remote-screen-close'),
            ),
            if (session.poor)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  LucideIcons.wifiLow,
                  key: Key('remote-screen-poor'),
                  size: 18,
                  color: Colors.white70,
                ),
              ),
            button(
              mode == PointerMode.touchpad
                  ? LucideIcons.squareMousePointer
                  : LucideIcons.pointer,
              mode == PointerMode.touchpad
                  ? l10n.pointerTouchpad
                  : l10n.pointerDirect,
              onMode,
              key: const Key('remote-screen-mode'),
            ),
            button(
              LucideIcons.keyboard,
              l10n.keyboard,
              onKeyboard,
              on: keyboard,
              key: const Key('remote-screen-keyboard'),
            ),
            AnimatedSize(
              duration: BayaMotion.fast,
              child: zoomed
                  ? button(LucideIcons.minimize, l10n.fitScreen, onFit)
                  : const SizedBox.shrink(),
            ),
            PopupMenuButton<ScreenQuality>(
              tooltip: l10n.quality,
              icon: const Icon(
                LucideIcons.gauge,
                size: 20,
                color: Colors.white,
              ),
              initialValue: quality,
              onSelected: onQuality,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: ScreenQuality.best,
                  child: Text(l10n.qualityBest),
                ),
                PopupMenuItem(
                  value: ScreenQuality.balanced,
                  child: Text(l10n.qualityBalanced),
                ),
                PopupMenuItem(
                  value: ScreenQuality.saver,
                  child: Text(l10n.qualitySaver),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What a desktop needs that a phone keyboard lacks.
class _Keys extends StatelessWidget {
  const _Keys({
    required this.ctrl,
    required this.alt,
    required this.shift,
    required this.onCtrl,
    required this.onAlt,
    required this.onShift,
    required this.onKey,
  });

  final bool ctrl;
  final bool alt;
  final bool shift;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final VoidCallback onShift;
  final void Function(String key, {List<String> mods}) onKey;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, VoidCallback onTap, {bool on = false, Key? id}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2.5),
          child: Material(
            color: on ? Colors.white : Colors.white.withValues(alpha: .12),
            shape: const StadiumBorder(),
            child: InkWell(
              key: id,
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minWidth: 44),
                height: 36,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  label,
                  style: context.typo.monoSmall.copyWith(
                    fontSize: BayaType.footnote,
                    fontWeight: FontWeight.w600,
                    color: on ? Colors.black : Colors.white,
                  ),
                ),
              ),
            ),
          ),
        );
    return ColoredBox(
      color: Colors.black.withValues(alpha: .82),
      child: SizedBox(
        height: 48,
        child: ListView(
          key: const Key('remote-screen-keys'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          children: [
            key('esc', () => onKey('escape')),
            key('ctrl', onCtrl, on: ctrl, id: const Key('remote-key-ctrl')),
            key('alt', onAlt, on: alt),
            key('shift', onShift, on: shift),
            key('tab', () => onKey('tab')),
            key('win', () => onKey('win')),
            key('del', () => onKey('delete')),
            key('←', () => onKey('left')),
            key('↑', () => onKey('up')),
            key('↓', () => onKey('down')),
            key('→', () => onKey('right')),
            key(
              '⌃C',
              () => onKey('c', mods: const ['ctrl']),
              id: const Key('remote-key-copy'),
            ),
            key('⌃V', () => onKey('v', mods: const ['ctrl'])),
            key('⌃Z', () => onKey('z', mods: const ['ctrl'])),
            key('alt⇥', () => onKey('tab', mods: const ['alt'])),
            key('home', () => onKey('home')),
            key('end', () => onKey('end')),
            for (var i = 1; i <= 12; i++) key('F$i', () => onKey('f$i')),
          ],
        ),
      ),
    );
  }
}
