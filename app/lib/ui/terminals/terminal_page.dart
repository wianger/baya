/// One of the computer's terminals, full screen, made for a phone.
///
/// It opens for reading: no keyboard over half the screen. Pinch to change
/// the text size, which changes the terminal's columns too, so the program
/// on the computer lays itself out for this screen. Typing goes through a
/// composer by default (the phone's own keyboard, with autocorrect, voice
/// and paste), sent as one line; "keys" mode types straight into the
/// terminal. When the program waits for an answer, the answers are buttons.
/// The terminal outlives this page and every connection; coming back paints
/// it as it is now.
library;

import 'dart:async';
import 'dart:convert';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/terminals/herdr_terminals.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/terminals/ghostty_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xterm/xterm.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.repository,
    required this.terminal,
    this.online,
    this.fontSize = 13,
    this.onFontSize,
    this.engine = TerminalEngine.xterm,
  });

  final TerminalsRepository repository;
  final HerdrTerminal terminal;

  /// Whether the computer is reachable now, for the reconnecting note.
  final ValueListenable<bool>? online;

  /// The text size to start at, and where a pinch's result is kept.
  final double fontSize;
  final ValueChanged<double>? onFontSize;

  /// What draws it: xterm.dart, or the Ghostty trial.
  final TerminalEngine engine;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

/// Lines kept above the screen on the phone.
const _scrollback = 10000;
const _minFont = 7.0;
const _maxFont = 24.0;

enum _Input { compose, keys }

class _TerminalPageState extends State<TerminalPage> {
  late Terminal _terminal = _newTerminal();
  final _controller = TerminalController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _line = TextEditingController();
  final _lineFocus = FocusNode();
  late HerdrTerminal _info = widget.terminal;
  TerminalStream? _stream;
  StreamSubscription<void>? _bytes;
  StreamSubscription<void>? _resets;
  StreamSubscription<void>? _changes;
  late ByteConversionSink _decoder = _newDecoder();

  /// The Ghostty trial engine, when it draws this terminal.
  late final GhosttyController? _ghostty =
      widget.engine == TerminalEngine.ghostty
      ? GhosttyController(
          onOutput: (data) => _stream?.input(data),
        )
      : null;

  /// How fast xterm takes the bytes, beside Ghostty's numbers.
  final _xtermStats = TerminalStats();
  bool _attaching = false;
  String? _ended;
  String? _error;
  late double _fontSize = widget.fontSize.clamp(_minFont, _maxFont);
  _Input _input = _Input.compose;
  bool _atBottom = true;

  /// Scrolled to the oldest line the phone holds: older ones are a read
  /// away.
  bool _atTop = false;

  /// While pinching: the size it started at, and the grid to show.
  double? _pinchFrom;
  String? _grid;
  Timer? _gridHide;

  // One-shot modifiers from the key bar, for the next key typed.
  bool _ctrl = false;
  bool _alt = false;

  Terminal _newTerminal() => Terminal(maxLines: _scrollback)
    ..onOutput = _output
    ..onResize = _resized
    ..onBell = () => unawaited(HapticFeedback.heavyImpact());

  ByteConversionSink _newDecoder() => const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(_TerminalSink((text) => _terminal.write(text)));

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrolled);
    // Its status (waiting for an answer, working) as hc reports it.
    _changes = widget.repository.changes.listen((_) => _refresh());
  }

  @override
  void dispose() {
    unawaited(_bytes?.cancel());
    unawaited(_resets?.cancel());
    unawaited(_changes?.cancel());
    unawaited(_stream?.close());
    _gridHide?.cancel();
    _decoder.close();
    _ghostty?.dispose();
    _xtermStats.dispose();
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
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
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final atBottom = position.pixels >= position.maxScrollExtent - 4;
    final atTop =
        position.maxScrollExtent > 0 &&
        position.pixels <= position.minScrollExtent + 4;
    if (atBottom != _atBottom || atTop != _atTop) {
      setState(() {
        _atBottom = atBottom;
        _atTop = atTop;
      });
    }
  }

  void _toBottom() {
    if (_ghostty case final ghostty?) {
      ghostty.toBottom();
      return;
    }
    if (!_scroll.hasClients) return;
    unawaited(
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: BayaMotion.scroll,
        curve: BayaMotion.enter,
      ),
    );
  }

  /// The view laid out, rotated or zoomed: the first size attaches.
  void _resized(int cols, int rows, int _, int _) {
    // Called during layout: show the new grid once this frame is done.
    if (_pinchFrom != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showGrid(cols, rows);
      });
    }
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
      );
      if (!mounted) {
        await stream.close();
        return;
      }
      _stream = stream;
      final ghostty = _ghostty;
      _bytes = stream.bytes.listen(
        ghostty != null
            ? ghostty.write
            : (bytes) {
                final watch = Stopwatch()..start();
                _decoder.add(bytes);
                _xtermStats.wrote(bytes.length, watch.elapsed);
              },
      );
      _resets = stream.resets.listen((_) => _fresh());
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

  /// The computer paints the whole screen again after a reconnect.
  void _fresh() {
    if (_ghostty case final ghostty?) {
      ghostty.reset();
      return;
    }
    _decoder.close();
    final cols = _terminal.viewWidth;
    final rows = _terminal.viewHeight;
    setState(() {
      _terminal = _newTerminal()..resize(cols, rows);
      _decoder = _newDecoder();
    });
  }

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
  }

  void _key(TerminalKey key) {
    unawaited(HapticFeedback.selectionClick());
    final (ctrl, alt) = (_ctrl, _alt);
    if (ctrl || alt) setState(() => _ctrl = _alt = false);
    if (_ghostty != null) {
      _stream?.input(_keySequence(key, alt: alt));
      _toBottom();
      return;
    }
    // The terminal encodes the modifiers itself (and the cursor mode).
    _terminal.keyInput(key, ctrl: ctrl, alt: alt);
    _toBottom();
  }

  void _send(String text) {
    unawaited(HapticFeedback.selectionClick());
    _stream?.input(text);
    _toBottom();
  }

  /// The composer's line, as the program would take a paste, then Enter.
  void _submit() {
    final text = _line.text;
    unawaited(HapticFeedback.lightImpact());
    if (text.isNotEmpty) {
      if (_ghostty != null) {
        _stream?.input(text);
      } else {
        _terminal.paste(text);
      }
    }
    _stream?.input('\r');
    _line.clear();
    _toBottom();
  }

  void _toggleInput() {
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _input = _input == _Input.compose ? _Input.keys : _Input.compose;
    });
    // Once the view has rebuilt for the new mode (the raw keyboard only
    // attaches when the terminal takes soft input).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_input == _Input.keys) {
        _focus.requestFocus();
      } else {
        _lineFocus.requestFocus();
      }
    });
  }

  // ── pinch ──────────────────────────────────────────────────────────────

  final _pointers = <int, Offset>{};
  double? _pinchStart;

  double get _spread {
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  void _down(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      _pinchStart = _spread;
      _pinchFrom = _fontSize;
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    final start = _pinchStart;
    final from = _pinchFrom;
    if (_pointers.length < 2 || start == null || from == null || start < 8) {
      return;
    }
    final size = (from * _spread / start).clamp(_minFont, _maxFont);
    // Half-point steps: each one changes the grid, so not every frame.
    final stepped = (size * 2).roundToDouble() / 2;
    if (stepped != _fontSize) setState(() => _fontSize = stepped);
  }

  void _up(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2 && _pinchFrom != null) {
      if (_fontSize != _pinchFrom) {
        unawaited(HapticFeedback.selectionClick());
        widget.onFontSize?.call(_fontSize);
      }
      _pinchFrom = null;
      _pinchStart = null;
    }
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

  TerminalTheme _theme(AppColors colors, Brightness brightness) {
    final base = brightness == Brightness.dark
        ? TerminalThemes.defaultTheme
        : _lightAnsi;
    return TerminalTheme(
      cursor: colors.text,
      selection: colors.text.withValues(alpha: .22),
      foreground: colors.text,
      background: colors.bg,
      black: base.black,
      red: base.red,
      green: base.green,
      yellow: base.yellow,
      blue: base.blue,
      magenta: base.magenta,
      cyan: base.cyan,
      white: base.white,
      brightBlack: base.brightBlack,
      brightRed: base.brightRed,
      brightGreen: base.brightGreen,
      brightYellow: base.brightYellow,
      brightBlue: base.brightBlue,
      brightMagenta: base.brightMagenta,
      brightCyan: base.brightCyan,
      brightWhite: base.brightWhite,
      searchHitBackground: colors.muted,
      searchHitBackgroundCurrent: colors.text,
      searchHitForeground: colors.bg,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final info = _info;
    final brightness = Theme.of(context).brightness;
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
                    child: _ghostty != null
                        ? GhosttyView(
                            controller: _ghostty,
                            fontSize: _fontSize,
                            onResize: (cols, rows) =>
                                _resized(cols, rows, 0, 0),
                          )
                        : TerminalView(
                            _terminal,
                            key: ObjectKey(_terminal),
                            controller: _controller,
                            scrollController: _scroll,
                            focusNode: _focus,
                            readOnly: !live,
                            // Composing: a tap selects or scrolls, it does not
                            // bring the raw keyboard up.
                            hardwareKeyboardOnly: _input == _Input.compose,
                            theme: _theme(colors, brightness),
                            keyboardAppearance: brightness,
                            keyboardType: TextInputType.visiblePassword,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            textStyle: TerminalStyle(
                              fontSize: _fontSize,
                              fontFamily: kMonoFamily,
                              // Prompts (starship, powerline) and TUIs draw icons
                              // from Nerd Fonts' private-use glyphs.
                              fontFamilyFallback: const [
                                'Symbols Nerd Font Mono',
                                'Noto Sans Mono CJK SC',
                                'Noto Color Emoji',
                                'Noto Sans Symbols',
                                'Noto Sans Symbols 2',
                              ],
                            ),
                          ),
                  ),
                  // While engines are compared: how fast this one parses,
                  // and (Ghostty) how long a frame takes to paint.
                  Positioned(
                    left: 10,
                    bottom: 8,
                    child: IgnorePointer(
                      child: ListenableBuilder(
                        listenable: _ghostty?.stats ?? _xtermStats,
                        builder: (context, _) {
                          final stats = _ghostty?.stats ?? _xtermStats;
                          return Text(
                            _ghostty != null
                                ? 'Ghostty · $stats'
                                : 'xterm · '
                                      '${stats.mbPerSecond.toStringAsFixed(1)}'
                                      ' MB/s',
                            key: const Key('terminal-engine-stats'),
                            style: context.typo.monoSmall.copyWith(
                              fontSize: 10,
                              color: colors.muted.withValues(alpha: .7),
                            ),
                          );
                        },
                      ),
                    ),
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
                  // Further back than the attach sent: the whole history as
                  // text, on its own page.
                  Positioned(
                    top: 10,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: AnimatedScale(
                        scale: _atTop ? 1 : 0,
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
                      scale: _atBottom ? 0 : 1,
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
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSubmit(),
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
  final ValueChanged<TerminalKey> onKey;
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
            key('esc', onTap: () => onKey(TerminalKey.escape)),
            key(
              'ctrl',
              id: const Key('terminal-key-ctrl'),
              on: ctrl,
              onTap: onCtrl,
            ),
            key('alt', on: alt, onTap: onAlt),
            key('tab', onTap: () => onKey(TerminalKey.tab)),
            key(
              '^C',
              id: const Key('terminal-key-interrupt'),
              onTap: () => onText('\x03'),
            ),
            key(
              '←',
              icon: LucideIcons.arrowLeft,
              onTap: () => onKey(TerminalKey.arrowLeft),
            ),
            key(
              '↑',
              icon: LucideIcons.arrowUp,
              onTap: () => onKey(TerminalKey.arrowUp),
            ),
            key(
              '↓',
              icon: LucideIcons.arrowDown,
              onTap: () => onKey(TerminalKey.arrowDown),
            ),
            key(
              '→',
              icon: LucideIcons.arrowRight,
              onTap: () => onKey(TerminalKey.arrowRight),
            ),
            for (final symbol in const ['/', '-', '|', '~', '*', r'$'])
              key(symbol, onTap: () => onText(symbol)),
            key('home', onTap: () => onKey(TerminalKey.home)),
            key('end', onTap: () => onKey(TerminalKey.end)),
            key('pgup', onTap: () => onKey(TerminalKey.pageUp)),
            key('pgdn', onTap: () => onKey(TerminalKey.pageDown)),
          ],
        ),
      ),
    );
  }
}

class _TerminalSink implements Sink<String> {
  _TerminalSink(this._write);
  final void Function(String) _write;
  @override
  void add(String data) => _write(data);
  @override
  void close() {}
}

/// ANSI colors that read on white.
const _lightAnsi = TerminalTheme(
  cursor: Color(0xFF000000),
  selection: Color(0x33000000),
  foreground: Color(0xFF0A0A0A),
  background: Color(0xFFFFFFFF),
  black: Color(0xFF000000),
  red: Color(0xFFC62A22),
  green: Color(0xFF1E7B34),
  yellow: Color(0xFF8A6A00),
  blue: Color(0xFF1F5FBF),
  magenta: Color(0xFF8E3FB5),
  cyan: Color(0xFF0F7A80),
  white: Color(0xFFBFBFBF),
  brightBlack: Color(0xFF6B6B6B),
  brightRed: Color(0xFFE0443B),
  brightGreen: Color(0xFF2E9E4A),
  brightYellow: Color(0xFFA88400),
  brightBlue: Color(0xFF3B7BE0),
  brightMagenta: Color(0xFFA858D0),
  brightCyan: Color(0xFF1A9AA0),
  brightWhite: Color(0xFF5A5A5A),
  searchHitBackground: Color(0xFFBFBFBF),
  searchHitBackgroundCurrent: Color(0xFF000000),
  searchHitForeground: Color(0xFFFFFFFF),
);

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

/// What the key bar's keys send, for the Ghostty trial (xterm encodes its
/// own). Normal cursor mode, as shells and most TUIs expect.
String _keySequence(TerminalKey key, {required bool alt}) {
  final sequence = switch (key) {
    TerminalKey.escape => '\x1b',
    TerminalKey.tab => '\t',
    TerminalKey.enter => '\r',
    TerminalKey.backspace => '\x7f',
    TerminalKey.arrowUp => '\x1b[A',
    TerminalKey.arrowDown => '\x1b[B',
    TerminalKey.arrowRight => '\x1b[C',
    TerminalKey.arrowLeft => '\x1b[D',
    TerminalKey.home => '\x1b[H',
    TerminalKey.end => '\x1b[F',
    TerminalKey.pageUp => '\x1b[5~',
    TerminalKey.pageDown => '\x1b[6~',
    TerminalKey.delete => '\x1b[3~',
    _ => '',
  };
  return alt && sequence.isNotEmpty ? '\x1b$sequence' : sequence;
}
