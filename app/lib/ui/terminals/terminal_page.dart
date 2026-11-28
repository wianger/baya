/// One of the computer's terminals, full screen, made for a phone, drawn
/// by Ghostty's terminal engine (libghostty-vt: the computer's own widths
/// for CJK, emoji and icons).
///
/// It opens for reading: no keyboard over half the screen until asked for
/// (a tap). Pinch to change the text size, which changes the terminal's
/// columns too, so the program on the computer lays itself out for this
/// screen. Dragging scrolls: a full-screen program's own history through
/// its wheel, a shell's scrollback here; a flick keeps going. Hold to read
/// and copy the history as text. Typing goes through a composer by default
/// (the phone's own keyboard, with autocorrect, voice and paste), sent with
/// the send button; "keys" mode types straight into the terminal. When the
/// program waits for an answer, the answers are buttons. The terminal
/// outlives this page and every connection; coming back paints it as it is
/// now.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:app/data/terminals/herdr_terminals.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/terminals/ghostty_view.dart';
import 'package:app/ui/terminals/wheel_driver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.repository,
    required this.terminal,
    this.online,
    this.fontSize = 13,
    this.onFontSize,
    this.fixed = false,
  });

  final TerminalsRepository repository;
  final HerdrTerminal terminal;

  /// Whether the computer is reachable now, for the reconnecting note.
  final ValueListenable<bool>? online;

  /// The text size to start at, and where a pinch's result is kept.
  final double fontSize;
  final ValueChanged<double>? onFontSize;

  /// Shown at its own size, which the computer keeps (a pane shown there
  /// too): wider than the phone, it is dragged sideways to see all of it.
  final bool fixed;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

const _minFont = 7.0;
const _maxFont = 24.0;

enum _Input { compose, keys }

class _TerminalPageState extends State<TerminalPage> {
  late final _ghostty = GhosttyController(onOutput: (data) => _stream?.input(data));
  final _keysFocus = FocusNode();
  final _line = TextEditingController();
  final _lineFocus = FocusNode();
  late HerdrTerminal _info = widget.terminal;
  TerminalStream? _stream;
  StreamSubscription<void>? _bytes;
  StreamSubscription<void>? _resets;
  StreamSubscription<void>? _sizes;
  StreamSubscription<void>? _changes;

  /// A fixed terminal's size on the computer.
  late (int, int) _size = (
    widget.terminal.cols ?? 80,
    widget.terminal.rows ?? 24,
  );

  bool _attaching = false;
  String? _ended;
  String? _error;
  late double _fontSize = widget.fontSize.clamp(_minFont, _maxFont);
  _Input _input = _Input.compose;

  /// Scrolled back from the newest output: the way back down shows.
  bool _scrolledBack = false;

  /// While pinching: the size it started at, and the grid to show.
  double? _pinchFrom;
  String? _grid;
  Timer? _gridHide;

  // One-shot modifiers from the key bar, for the next key typed.
  bool _ctrl = false;
  bool _alt = false;

  /// What the program asked of the screen, read from its bytes: what a
  /// drag means, how keys and pastes are sent.
  final _modes = ScreenModes();

  @override
  void initState() {
    super.initState();
    _ghostty.addListener(_scrolled);
    // Its status (waiting for an answer, working) as hc reports it.
    _changes = widget.repository.changes.listen((_) => _refresh());
    // At its own size: no layout to wait for.
    if (widget.fixed) {
      _ghostty.resize(_size.$1, _size.$2, 8, 16);
      unawaited(_attach(_size.$1, _size.$2));
    }
  }

  @override
  void dispose() {
    unawaited(_bytes?.cancel());
    unawaited(_resets?.cancel());
    unawaited(_sizes?.cancel());
    unawaited(_changes?.cancel());
    unawaited(_stream?.close());
    _gridHide?.cancel();
    _hold?.cancel();
    _wheel.dispose();
    _ghostty
      ..removeListener(_scrolled)
      ..dispose();
    _keysFocus.dispose();
    _line.dispose();
    _lineFocus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final list = await widget.repository.list();
      final now = list.terminals.where(
        (t) => t.address == widget.terminal.address,
      );
      if (mounted && now.isNotEmpty) setState(() => _info = now.first);
    } catch (_) {
      // Offline: the status shows again once it is back.
    }
  }

  void _scrolled() {
    final back = _ghostty.scrolledBack > 0;
    if (back != _scrolledBack && mounted) setState(() => _scrolledBack = back);
  }

  void _toBottom() => _ghostty.toBottom();

  /// The view laid out, rotated or zoomed: the first size attaches.
  void _resized(int cols, int rows) {
    // Its size is the computer's.
    if (widget.fixed) return;
    if (_pinchFrom != null) _showGrid(cols, rows);
    final stream = _stream;
    if (stream != null) {
      stream.resize(cols, rows);
    } else {
      unawaited(_attach(cols, rows));
    }
  }

  void _showGrid(int cols, int rows) {
    _gridHide?.cancel();
    setState(() => _grid = '$cols × $rows');
    _gridHide = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _grid = null);
    });
  }

  Future<void> _attach(int cols, int rows) async {
    if (_attaching || _stream != null || _ended != null) return;
    _attaching = true;
    try {
      final (stream, info) = await widget.repository.attach(
        widget.terminal.address,
        cols: cols,
        rows: rows,
        observe: widget.fixed,
      );
      if (!mounted) {
        await stream.close();
        return;
      }
      _stream = stream;
      _bytes = stream.bytes.listen((bytes) {
        _modes.feed(bytes);
        _ghostty.write(bytes);
      });
      _resets = stream.resets.listen((_) => _ghostty.reset());
      _sizes = stream.sizes.listen(_sized);
      unawaited(
        stream.ended.then((reason) {
          if (mounted) setState(() => _ended = reason);
        }),
      );
      setState(() {
        _info = info;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      _attaching = false;
    }
  }

  /// A fixed terminal resized on the computer.
  void _sized((int, int) size) {
    if (size == _size) return;
    setState(() => _size = size);
    _ghostty.resize(size.$1, size.$2, 8, 16);
  }

  /// Text typed straight into the terminal, with the key bar's one-shot
  /// Ctrl or Alt on its first character.
  void _output(String data) {
    var out = data;
    if (_ctrl && out.length == 1) {
      final code = out.toLowerCase().codeUnitAt(0);
      if (code >= 0x61 && code <= 0x7a) {
        out = String.fromCharCode(code - 0x60);
      } else if (code >= 0x5b && code <= 0x5f) {
        out = String.fromCharCode(code - 0x40);
      } else if (code == 0x20) {
        out = '\x00';
      }
    }
    if (_alt) out = '\x1b$out';
    if (_ctrl || _alt) setState(() => _ctrl = _alt = false);
    _stream?.input(out);
    _toBottom();
  }

  void _key(_Key key) {
    unawaited(HapticFeedback.selectionClick());
    final alt = _alt;
    if (_ctrl || _alt) setState(() => _ctrl = _alt = false);
    _stream?.input(key.sequence(alt: alt, application: _modes.cursorKeys));
    _toBottom();
  }

  void _send(String text) {
    unawaited(HapticFeedback.selectionClick());
    _stream?.input(text);
    _toBottom();
  }

  /// The composer's line, as the program takes a paste, then Enter.
  void _submit() {
    final text = _line.text;
    unawaited(HapticFeedback.lightImpact());
    if (text.isNotEmpty) {
      _stream?.input(
        _modes.bracketedPaste ? '\x1b[200~$text\x1b[201~' : text,
      );
    }
    _stream?.input('\r');
    _line.clear();
    _toBottom();
  }

  /// A tap on the terminal is for typing: the keyboard comes up, for the
  /// line composed or (keys mode) straight into the terminal.
  void _tapped() {
    if (_ended != null) return;
    (_input == _Input.compose ? _lineFocus : _keysFocus).requestFocus();
    if (_input == _Input.keys) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    }
  }

  void _toggleInput() {
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _input = _input == _Input.compose ? _Input.keys : _Input.compose;
    });
    // Once the view has rebuilt for the new mode.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_input == _Input.keys ? _keysFocus : _lineFocus).requestFocus();
    });
  }

  // ── touch: tap, hold, drag, pinch ─────────────────────────────────────

  final _pointers = <int, Offset>{};
  double? _pinchStart;

  double get _spread {
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  /// Where and when a one-finger touch began, to tell a tap from a drag.
  (Offset, Duration)? _touch;

  /// Holding still opens the history as text, to select and copy.
  Timer? _hold;

  /// A drag turns the program's wheel (a full-screen program keeps its own
  /// history) or scrolls the scrollback here, flicks included.
  late final _wheel = WheelDriver(onTurns: _turn);

  void _down(PointerDownEvent event) {
    _wheel.stop();
    _pointers[event.pointer] = event.localPosition;
    _touch = _pointers.length == 1
        ? (event.localPosition, event.timeStamp)
        : null;
    _hold?.cancel();
    if (_pointers.length == 1) {
      _hold = Timer(const Duration(milliseconds: 550), () {
        _touch = null;
        unawaited(HapticFeedback.mediumImpact());
        unawaited(_openHistory());
      });
    }
    if (_pointers.length == 2) {
      _hold?.cancel();
      _pinchStart = _spread;
      _pinchFrom = _fontSize;
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    final touch = _touch;
    if (touch != null && (event.localPosition - touch.$1).distance > 12) {
      _hold?.cancel();
    }
    final start = _pinchStart;
    final from = _pinchFrom;
    if (_pointers.length == 2 && start != null && from != null && start > 8) {
      final size = (from * _spread / start).clamp(_minFont, _maxFont);
      // Half-point steps: each one changes the grid, so not every frame.
      final stepped = (size * 2).roundToDouble() / 2;
      if (stepped != _fontSize) setState(() => _fontSize = stepped);
      return;
    }
    // One finger, mostly up or down (sideways sees a wide terminal).
    if (_pointers.length != 1 ||
        event.delta.dy.abs() < event.delta.dx.abs()) {
      return;
    }
    _wheel
      ..line = _fontSize * 1.25
      ..drag(event.delta.dy, event.timeStamp);
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    _hold?.cancel();
    if (_pointers.isEmpty) _wheel.release();
    final touch = _touch;
    _touch = null;
    if (event is PointerUpEvent &&
        touch != null &&
        _pointers.isEmpty &&
        (event.localPosition - touch.$1).distance < 12 &&
        event.timeStamp - touch.$2 < const Duration(milliseconds: 350)) {
      _tapped();
    }
    if (_pointers.length < 2 && _pinchFrom != null) {
      if (_fontSize != _pinchFrom) {
        unawaited(HapticFeedback.selectionClick());
        widget.onFontSize?.call(_fontSize);
      }
      _pinchFrom = null;
      _pinchStart = null;
    }
  }

  /// [turns] of the wheel, up when positive: to a full-screen program, or
  /// this view's scrollback on the main screen.
  void _turn(int turns) {
    if (!_modes.alt) {
      _ghostty.scroll(-turns);
      return;
    }
    final up = turns > 0;
    // The middle of the screen, 1-based, where the program's main view is.
    final x = _ghostty.cols ~/ 2 + 1;
    final y = _ghostty.rows ~/ 2 + 1;
    final button = up ? 64 : 65;
    final one = !_modes.mouse
        ? (up ? '\x1b[A' : '\x1b[B')
        : _modes.sgr
        ? '\x1b[<$button;$x;${y}M'
        : '\x1b[M${String.fromCharCodes([32 + button, 32 + x, 32 + y])}';
    _stream?.input(one * turns.abs());
  }

  Future<void> _openHistory() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TerminalHistoryPage(
        title: _info.label,
        load: () => widget.repository.read(widget.terminal.address),
        fontSize: _fontSize,
      ),
    ),
  );

  /// A fixed terminal at its own size: wider than the phone, it is dragged
  /// sideways; taller, its bottom (where an agent asks) shows.
  Widget _fit(Widget view) {
    if (!widget.fixed) return view;
    return SingleChildScrollView(
      key: const Key('terminal-sideways'),
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        reverse: true,
        child: view,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final info = _info;
    final live = _ended == null;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: BayaHeader(
        title: info.label,
        subtitle: '${info.address} · ${info.folder}',
        monoSubtitle: true,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _Notice(online: widget.online, ended: _ended, error: _error),
            Expanded(
              child: Stack(
                children: [
                  Listener(
                    onPointerDown: _down,
                    onPointerMove: _move,
                    onPointerUp: _up,
                    onPointerCancel: _up,
                    child: _fit(
                      GhosttyView(
                        key: const Key('terminal-screen'),
                        controller: _ghostty,
                        fontSize: _fontSize,
                        fixed: widget.fixed,
                        onResize: _resized,
                      ),
                    ),
                  ),
                  // Keys mode: what the phone's keyboard types goes in.
                  if (live && _input == _Input.keys)
                    _RawKeys(
                      focus: _keysFocus,
                      onText: _output,
                      onKey: _key,
                    ),
                  // The grid while pinching: the program's new size.
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: AnimatedOpacity(
                          opacity: _grid == null ? 0 : 1,
                          duration: BayaMotion.fast,
                          child: _Pill(
                            key: const Key('terminal-grid'),
                            text: _grid ?? '',
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Back in the scrollback: further back is the whole
                  // history as text, on its own page.
                  Positioned(
                    top: 10,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: AnimatedScale(
                        scale: _scrolledBack ? 1 : 0,
                        duration: BayaMotion.standard,
                        curve: BayaMotion.spring,
                        child: ActionChip(
                          key: const Key('terminal-earlier'),
                          avatar: const Icon(LucideIcons.history, size: 16),
                          label: Text(l10n.earlierOutput),
                          onPressed: _openHistory,
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 14,
                    bottom: 12,
                    child: AnimatedScale(
                      scale: _scrolledBack ? 1 : 0,
                      duration: BayaMotion.standard,
                      curve: BayaMotion.spring,
                      child: FloatingActionButton.small(
                        key: const Key('terminal-to-bottom'),
                        heroTag: null,
                        tooltip: l10n.jumpToLatest,
                        elevation: 0,
                        backgroundColor: colors.text,
                        foregroundColor: colors.bg,
                        onPressed: _toBottom,
                        child: const Icon(LucideIcons.arrowDown, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (live) ...[
              AnimatedSize(
                duration: BayaMotion.standard,
                curve: BayaMotion.enter,
                child: info.needsYou
                    ? _Answers(status: info.status!, onAnswer: _send)
                    : const SizedBox(width: double.infinity),
              ),
              _KeyBar(
                ctrl: _ctrl,
                alt: _alt,
                onCtrl: () => setState(() => _ctrl = !_ctrl),
                onAlt: () => setState(() => _alt = !_alt),
                onKey: _key,
                onText: _send,
              ),
              _Composer(
                mode: _input,
                controller: _line,
                focus: _lineFocus,
                onSubmit: _submit,
                onToggle: _toggleInput,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Keys mode: the phone's keyboard typing straight into the terminal. An
/// invisible field holds a marker the keyboard edits: what is added goes in
/// as typed, what is taken away as Backspace; hardware keys go as their
/// sequences.
class _RawKeys extends StatefulWidget {
  const _RawKeys({
    required this.focus,
    required this.onText,
    required this.onKey,
  });

  final FocusNode focus;
  final ValueChanged<String> onText;
  final ValueChanged<_Key> onKey;

  @override
  State<_RawKeys> createState() => _RawKeysState();
}

class _RawKeysState extends State<_RawKeys> {
  /// What the field holds between keys: something to delete.
  static const _marker = '  ';
  final _field = TextEditingController(text: _marker);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _changed(String value) {
    if (_field.value.composing.isValid && !_field.value.composing.isCollapsed) {
      return;
    }
    if (value.length < _marker.length) {
      for (var i = value.length; i < _marker.length; i++) {
        widget.onKey(_Key.backspace);
      }
    } else if (value.length > _marker.length) {
      final typed = value.substring(_marker.length).replaceAll('\n', '\r');
      widget.onText(typed);
    }
    _field.value = const TextEditingValue(
      text: _marker,
      selection: TextSelection.collapsed(offset: _marker.length),
    );
  }

  KeyEventResult _hardware(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = switch (event.logicalKey) {
      LogicalKeyboardKey.escape => _Key.escape,
      LogicalKeyboardKey.tab => _Key.tab,
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => _Key.enter,
      LogicalKeyboardKey.backspace => _Key.backspace,
      LogicalKeyboardKey.arrowUp => _Key.up,
      LogicalKeyboardKey.arrowDown => _Key.down,
      LogicalKeyboardKey.arrowLeft => _Key.left,
      LogicalKeyboardKey.arrowRight => _Key.right,
      LogicalKeyboardKey.home => _Key.home,
      LogicalKeyboardKey.end => _Key.end,
      LogicalKeyboardKey.pageUp => _Key.pageUp,
      LogicalKeyboardKey.pageDown => _Key.pageDown,
      LogicalKeyboardKey.delete => _Key.delete,
      _ => null,
    };
    if (key == null) {
      // Ctrl+letter from a hardware keyboard.
      final char = event.character;
      if (HardwareKeyboard.instance.isControlPressed &&
          char != null &&
          char.length == 1) {
        final code = char.toLowerCase().codeUnitAt(0);
        if (code >= 0x61 && code <= 0x7a) {
          widget.onText(String.fromCharCode(code - 0x60));
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    widget.onKey(key);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    bottom: 0,
    width: 1,
    height: 1,
    child: Opacity(
      opacity: 0,
      child: Focus(
        onKeyEvent: _hardware,
        skipTraversal: true,
        child: TextField(
          key: const Key('terminal-raw-keys'),
          controller: _field,
          focusNode: widget.focus,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          maxLines: null,
          onChanged: _changed,
        ),
      ),
    ),
  );
}

/// When the program waits: what it asks, and answers as buttons.
class _Answers extends StatelessWidget {
  const _Answers({required this.status, required this.onAnswer});

  final TerminalStatus status;
  final ValueChanged<String> onAnswer;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    // Agents' prompts pick by number or y/n, confirm with Enter.
    final answers = <(String, String, Key)>[
      ('1', '1', const Key('terminal-answer-1')),
      ('2', '2', const Key('terminal-answer-2')),
      ('3', '3', const Key('terminal-answer-3')),
      ('y', 'y', const Key('terminal-answer-y')),
      ('n', 'n', const Key('terminal-answer-n')),
      (l10n.enterKey, '\r', const Key('terminal-answer-enter')),
    ];
    return Container(
      key: const Key('terminal-answers'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.messageCircleQuestionMark,
                size: 16,
                color: colors.text,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status.message ?? l10n.terminalStateBlocked,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.sansBody.copyWith(
                    fontSize: BayaType.footnote,
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (label, keys, key) in answers)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: OutlinedButton(
                      key: key,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(46, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        textStyle: context.typo.mono.copyWith(
                          fontSize: BayaType.subhead,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: () => onAnswer(keys),
                      child: Text(label),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The phone's way to type: a line written with the phone's keyboard, sent
/// with Enter; or, toggled, keys straight into the terminal.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.mode,
    required this.controller,
    required this.focus,
    required this.onSubmit,
    required this.onToggle,
  });

  final _Input mode;
  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onSubmit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final composing = mode == _Input.compose;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      color: colors.bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            key: const Key('terminal-input-mode'),
            tooltip: composing ? l10n.typeIntoTerminal : l10n.composeLine,
            onPressed: onToggle,
            icon: Icon(
              composing ? LucideIcons.keyboard : LucideIcons.messageSquareText,
              size: 20,
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: BayaMotion.fast,
              child: composing
                  ? TextField(
                      key: const Key('terminal-compose'),
                      controller: controller,
                      focusNode: focus,
                      minLines: 1,
                      maxLines: 4,
                      // Enter is a new line; the send button sends.
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: context.typo.sansBody.copyWith(
                        fontSize: BayaType.body,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: l10n.terminalComposeHint,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: colors.inputFill,
                      ),
                    )
                  : Padding(
                      key: const Key('terminal-keys-mode'),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        l10n.typingIntoTerminal,
                        style: context.typo.sansBody.copyWith(
                          fontSize: BayaType.footnote,
                          color: colors.muted,
                        ),
                      ),
                    ),
            ),
          ),
          if (composing)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: IconButton.filled(
                key: const Key('terminal-send'),
                tooltip: l10n.sendMessage,
                style: IconButton.styleFrom(
                  backgroundColor: colors.text,
                  foregroundColor: colors.bg,
                ),
                onPressed: onSubmit,
                icon: const Icon(LucideIcons.cornerDownLeft, size: 18),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.text,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          text,
          style: context.typo.monoSmall.copyWith(
            fontSize: BayaType.caption,
            fontWeight: FontWeight.w600,
            color: colors.bg,
          ),
        ),
      ),
    );
  }
}

/// Above the screen: reconnecting, ended, or why it would not open.
class _Notice extends StatelessWidget {
  const _Notice({required this.online, required this.ended, this.error});

  final ValueListenable<bool>? online;
  final String? ended;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ValueListenableBuilder<bool>(
      valueListenable: online ?? const _Always(),
      builder: (context, isOnline, _) {
        final text =
            error ??
            (ended != null
                ? l10n.terminalEnded(ended!)
                : (isOnline ? null : l10n.terminalReconnecting));
        return AnimatedSize(
          duration: BayaMotion.standard,
          curve: BayaMotion.enter,
          alignment: Alignment.topCenter,
          child: text == null
              ? const SizedBox(width: double.infinity)
              : Container(
                  key: const Key('terminal-notice'),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  color: context.colors.inputFill,
                  child: Text(
                    text,
                    style: context.typo.sansBody.copyWith(
                      fontSize: BayaType.footnote,
                      color: error != null
                          ? context.colors.error
                          : context.colors.muted2,
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _Always implements ValueListenable<bool> {
  const _Always();
  @override
  bool get value => true;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

/// The keys a phone keyboard lacks: Esc, Tab, Ctrl and Alt (for the next
/// key), arrows, and the symbols shells want most.
class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.ctrl,
    required this.alt,
    required this.onCtrl,
    required this.onAlt,
    required this.onKey,
    required this.onText,
  });

  final bool ctrl;
  final bool alt;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final ValueChanged<_Key> onKey;
  final ValueChanged<String> onText;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget key(
      String label, {
      required VoidCallback onTap,
      bool on = false,
      IconData? icon,
      Key? id,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: Material(
        color: on ? colors.text : colors.inputFill,
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
            child: icon != null
                ? Icon(icon, size: 18, color: on ? colors.bg : colors.text)
                : Text(
                    label,
                    style: context.typo.monoSmall.copyWith(
                      fontSize: BayaType.footnote,
                      fontWeight: FontWeight.w600,
                      color: on ? colors.bg : colors.text,
                    ),
                  ),
          ),
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SizedBox(
        height: 48,
        child: ListView(
          key: const Key('terminal-keys'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          children: [
            key('esc', onTap: () => onKey(_Key.escape)),
            key(
              'ctrl',
              id: const Key('terminal-key-ctrl'),
              on: ctrl,
              onTap: onCtrl,
            ),
            key('alt', on: alt, onTap: onAlt),
            key('tab', onTap: () => onKey(_Key.tab)),
            key(
              '^C',
              id: const Key('terminal-key-interrupt'),
              onTap: () => onText('\x03'),
            ),
            key(
              '←',
              icon: LucideIcons.arrowLeft,
              onTap: () => onKey(_Key.left),
            ),
            key(
              '↑',
              icon: LucideIcons.arrowUp,
              onTap: () => onKey(_Key.up),
            ),
            key(
              '↓',
              icon: LucideIcons.arrowDown,
              onTap: () => onKey(_Key.down),
            ),
            key(
              '→',
              icon: LucideIcons.arrowRight,
              onTap: () => onKey(_Key.right),
            ),
            for (final symbol in const ['/', '-', '|', '~', '*', r'$'])
              key(symbol, onTap: () => onText(symbol)),
            key('home', onTap: () => onKey(_Key.home)),
            key('end', onTap: () => onKey(_Key.end)),
            key('pgup', onTap: () => onKey(_Key.pageUp)),
            key('pgdn', onTap: () => onKey(_Key.pageDown)),
          ],
        ),
      ),
    );
  }
}

/// A terminal's history as far back as the computer keeps it, as plain
/// text: read-only, selectable, opening at the newest line.
class TerminalHistoryPage extends StatefulWidget {
  const TerminalHistoryPage({
    super.key,
    required this.title,
    required this.load,
    this.fontSize = 13,
  });

  final String title;
  final Future<String> Function() load;
  final double fontSize;

  @override
  State<TerminalHistoryPage> createState() => _TerminalHistoryPageState();
}

class _TerminalHistoryPageState extends State<TerminalHistoryPage> {
  late final Future<List<String>> _lines = widget.load().then(
    (text) => text.trimRight().split('\n'),
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final style = context.typo.mono.copyWith(
      fontSize: widget.fontSize,
      height: 1.35,
      color: colors.text,
    );
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: BayaHeader(title: l10n.earlierOutput, subtitle: widget.title),
      body: FutureBuilder<List<String>>(
        future: _lines,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted),
                ),
              ),
            );
          }
          final lines = snapshot.data;
          if (lines == null) {
            return const Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              ),
            );
          }
          // Newest at the bottom, where it opens; only the lines on screen
          // are built, however long the history.
          return SelectionArea(
            child: ListView.builder(
              key: const Key('terminal-history'),
              reverse: true,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
              itemCount: lines.length,
              itemBuilder: (_, i) => Text(
                lines[lines.length - 1 - i],
                style: style,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The keys a phone keyboard lacks, as the key bar and keys mode send them.
enum _Key {
  escape,
  tab,
  enter,
  backspace,
  up,
  down,
  right,
  left,
  home,
  end,
  pageUp,
  pageDown,
  delete;

  /// Its bytes; arrows in the program's cursor mode (`application`: SS3,
  /// as vim and less ask for), [alt] as a leading Esc.
  String sequence({required bool alt, bool application = false}) {
    final arrow = application ? '\x1bO' : '\x1b[';
    final out = switch (this) {
      escape => '\x1b',
      tab => '\t',
      enter => '\r',
      backspace => '\x7f',
      up => '${arrow}A',
      down => '${arrow}B',
      right => '${arrow}C',
      left => '${arrow}D',
      home => '${arrow}H',
      end => '${arrow}F',
      pageUp => '\x1b[5~',
      pageDown => '\x1b[6~',
      delete => '\x1b[3~',
    };
    return alt ? '\x1b$out' : out;
  }
}

/// The private modes a program set that change what a drag means: the
/// alternate screen (a full-screen program), mouse reporting, SGR codes.
@visibleForTesting
class ScreenModes {
  bool alt = false;
  bool mouse = false;
  bool sgr = false;

  /// Arrows in application mode (DECCKM).
  bool cursorKeys = false;

  /// Pastes wrapped so the program takes them as one (2004).
  bool bracketedPaste = false;

  static final _set = RegExp(r'\x1b\[\?([\d;]+)([hl])');
  String _tail = '';

  void feed(List<int> bytes) {
    // Latin-1 keeps every byte one character: the escapes are ASCII.
    final text = _tail + String.fromCharCodes(bytes);
    for (final m in _set.allMatches(text)) {
      final on = m.group(2) == 'h';
      for (final mode in m.group(1)!.split(';')) {
        switch (mode) {
          case '47' || '1047' || '1049':
            alt = on;
          case '9' || '1000' || '1002' || '1003':
            mouse = on;
          case '1006':
            sgr = on;
          case '1':
            cursorKeys = on;
          case '2004':
            bracketedPaste = on;
        }
      }
    }
    // An escape cut across two chunks is read with the next one.
    final cut = text.lastIndexOf('\x1b');
    _tail = cut >= 0 && text.length - cut < 24 ? text.substring(cut) : '';
  }
}
