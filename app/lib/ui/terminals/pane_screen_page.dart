/// A session's terminal when its agent runs in a tab of herdr's TUI: that
/// pane's screen, exactly as herdr shows it on the computer, drawn cell by
/// cell at its own size and dragged sideways when wider than the phone.
/// Dragging up and down turns the program's wheel (full-screen agents keep
/// their own history); pinch sizes the text; a tap brings the keyboard up
/// for the line typed into the pane.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:app/data/hosts/host_connection.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/terminals/ghostty_view.dart';
import 'package:app/ui/terminals/wheel_driver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class PaneScreenPage extends StatefulWidget {
  const PaneScreenPage({
    super.key,
    required this.host,
    required this.sessionId,
    required this.title,
  });

  final HostConnection host;
  final String sessionId;
  final String title;

  @override
  State<PaneScreenPage> createState() => _PaneScreenPageState();
}

final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07]*\x07');

/// Cells a line takes: wide characters (CJK, emoji) take two.
int _cells(String line) {
  var n = 0;
  for (final rune in line.replaceAll(_ansi, '').runes) {
    final wide =
        (rune >= 0x1100 && rune <= 0x115F) ||
        (rune >= 0x2E80 && rune <= 0xA4CF) ||
        (rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFE30 && rune <= 0xFE4F) ||
        (rune >= 0xFF00 && rune <= 0xFF60) ||
        (rune >= 0xFFE0 && rune <= 0xFFE6) ||
        (rune >= 0x1F300 && rune <= 0x1FAFF);
    n += wide ? 2 : 1;
  }
  return n;
}

class _PaneScreenPageState extends State<PaneScreenPage> {
  late final _screen = GhosttyController(onOutput: (_) {});
  final _line = TextEditingController();
  final _lineFocus = FocusNode();
  double _font = 13;

  // One finger: a tap, or a drag that turns the wheel. Two: a pinch.
  final _pointers = <int, Offset>{};
  (Offset, Duration)? _touch;
  late final _wheel = WheelDriver(onTurns: _turn, every: const Duration(milliseconds: 80));
  double? _pinchStart;
  double? _pinchFrom;
  Timer? _poll;
  String _last = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _wheel.dispose();
    _screen.dispose();
    _line.dispose();
    _lineFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final result = await widget.host.call('_baya/pane_screen', {
        'sessionId': widget.sessionId,
      });
      final text = result['text'] as String? ?? '';
      if (!mounted || text == _last) return;
      _last = text;
      final lines = text.replaceAll('\r\n', '\n').split('\n');
      final cols = math.max(20, lines.map(_cells).fold(0, math.max));
      _screen
        ..reset()
        ..resize(cols, math.max(1, lines.length), 8, 16)
        ..write(
          Uint8List.fromList(utf8.encode('\x1b[H\x1b[2J${lines.join('\r\n')}')),
        );
      setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      _busy = false;
    }
  }

  Future<void> _input({
    String? text,
    List<String> keys = const [],
    bool haptic = true,
  }) async {
    if (haptic) unawaited(HapticFeedback.selectionClick());
    try {
      await widget.host.call('_baya/pane_input', {
        'sessionId': widget.sessionId,
        'text': ?text,
        if (keys.isNotEmpty) 'keys': keys,
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 150), _refresh),
    );
  }

  double get _spread {
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  void _down(PointerDownEvent event) {
    _wheel.stop();
    _pointers[event.pointer] = event.localPosition;
    _touch = _pointers.length == 1
        ? (event.localPosition, event.timeStamp)
        : null;
    if (_pointers.length == 2) {
      _pinchStart = _spread;
      _pinchFrom = _font;
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    final start = _pinchStart;
    final from = _pinchFrom;
    if (_pointers.length == 2 && start != null && from != null && start > 8) {
      final size = (from * _spread / start).clamp(7.0, 24.0);
      final stepped = (size * 2).roundToDouble() / 2;
      if (stepped != _font) setState(() => _font = stepped);
      return;
    }
    // Mostly sideways is seeing the rest of a wide screen.
    if (_pointers.length != 1 ||
        event.delta.dy.abs() < event.delta.dx.abs()) {
      return;
    }
    _wheel
      ..line = _font * 1.25
      ..drag(event.delta.dy, event.timeStamp);
  }

  /// [turns] of the program's wheel (up when positive), in one trip to herdr.
  void _turn(int turns) {
    final x = _screen.cols ~/ 2 + 1;
    final y = _screen.rows ~/ 2 + 1;
    final one = '\x1b[<${turns > 0 ? 64 : 65};$x;${y}M';
    unawaited(_input(text: one * turns.abs(), haptic: false));
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _pinchStart = null;
      _pinchFrom = null;
    }
    final touch = _touch;
    _touch = null;
    if (event is PointerUpEvent &&
        touch != null &&
        _pointers.isEmpty &&
        (event.localPosition - touch.$1).distance < 12 &&
        event.timeStamp - touch.$2 < const Duration(milliseconds: 350)) {
      _lineFocus.requestFocus();
    }
    if (_pointers.isEmpty) _wheel.release();
  }

  void _submit() {
    final text = _line.text;
    _line.clear();
    unawaited(_input(text: text.isEmpty ? null : text, keys: ['enter']));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    Widget key(String label, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: ActionChip(
        label: Text(label),
        onPressed: onTap,
        shape: const StadiumBorder(),
        labelStyle: context.typo.monoSmall.copyWith(
          fontSize: BayaType.footnote,
        ),
      ),
    );
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: BayaHeader(title: widget.title, subtitle: l10n.paneScreenHint),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: colors.error,
                    fontSize: BayaType.caption,
                  ),
                ),
              ),
            // The pane at its own size, the rest of it a drag sideways.
            Expanded(
              child: Listener(
                onPointerDown: _down,
                onPointerMove: _move,
                onPointerUp: _up,
                onPointerCancel: _up,
                child: SingleChildScrollView(
                  key: const Key('pane-screen-sideways'),
                  scrollDirection: Axis.horizontal,
                  // Up and down is the program's wheel, not this view.
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    reverse: true,
                    child: GhosttyView(
                      key: const Key('pane-screen'),
                      controller: _screen,
                      fontSize: _font,
                      fixed: true,
                      onResize: (_, _) {},
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  key('esc', () => _input(keys: ['esc'])),
                  key('⏎', () => _input(keys: ['enter'])),
                  key('↑', () => _input(keys: ['up'])),
                  key('↓', () => _input(keys: ['down'])),
                  key('←', () => _input(keys: ['left'])),
                  key('→', () => _input(keys: ['right'])),
                  key('tab', () => _input(keys: ['tab'])),
                  key('1', () => _input(text: '1')),
                  key('2', () => _input(text: '2')),
                  key('3', () => _input(text: '3')),
                  key('^C', () => _input(keys: ['ctrl+c'])),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('pane-screen-input'),
                      controller: _line,
                      focusNode: _lineFocus,
                      // Enter is a new line; the send button sends.
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: l10n.paneScreenType,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: l10n.sendMessage,
                    onPressed: _submit,
                    icon: const Icon(LucideIcons.cornerDownLeft, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
