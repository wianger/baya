/// One of the computer's terminals, full screen: the program's own screen,
/// live, with the keys a phone keyboard lacks over it. It outlives this
/// page and every connection; coming back paints it as it is now.
library;

import 'dart:async';
import 'dart:convert';

import 'package:app/data/terminals/herdr_terminals.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_dialog.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
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
  });

  final TerminalsRepository repository;
  final HerdrTerminal terminal;

  /// Whether the computer is reachable now, for the reconnecting note.
  final ValueListenable<bool>? online;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

/// Lines kept above the screen on the phone.
const _scrollback = 10000;

class _TerminalPageState extends State<TerminalPage> {
  late Terminal _terminal = _newTerminal();
  final _controller = TerminalController();
  final _focus = FocusNode();
  late HerdrTerminal _info = widget.terminal;
  TerminalStream? _stream;
  StreamSubscription<void>? _bytes;
  StreamSubscription<void>? _resets;
  late ByteConversionSink _decoder = _newDecoder();
  bool _attaching = false;
  String? _ended;
  String? _error;
  double _fontSize = 13;

  // One-shot modifiers from the key bar, for the next key typed.
  bool _ctrl = false;
  bool _alt = false;

  Terminal _newTerminal() => Terminal(maxLines: _scrollback)
    ..onOutput = _output
    ..onResize = _resized;

  ByteConversionSink _newDecoder() => const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(_TerminalSink((text) => _terminal.write(text)));

  @override
  void dispose() {
    unawaited(_bytes?.cancel());
    unawaited(_resets?.cancel());
    unawaited(_stream?.close());
    _decoder.close();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The view laid out (or rotated): the first size attaches.
  void _resized(int cols, int rows, int _, int _) {
    final stream = _stream;
    if (stream != null) {
      stream.resize(cols, rows);
    } else {
      unawaited(_attach(cols, rows));
    }
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
      _bytes = stream.bytes.listen(_decoder.add);
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
    // The terminal encodes the modifiers itself (and the cursor mode).
    _terminal.keyInput(key, ctrl: ctrl, alt: alt);
  }

  void _send(String text) {
    unawaited(HapticFeedback.selectionClick());
    _stream?.input(text);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) _terminal.paste(text);
  }

  Future<void> _end() async {
    final l10n = context.l10n;
    final go = await showBayaDialog<bool>(
      context: context,
      builder: (dialogContext) => BayaDialog(
        title: Text(l10n.endTerminalTitle),
        content: Text(
          l10n.endTerminalBody,
          style: TextStyle(color: dialogContext.colors.muted2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('terminal-end-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              l10n.endTerminal,
              style: TextStyle(color: dialogContext.colors.error),
            ),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      await widget.repository.kill(widget.terminal.address);
    } catch (error) {
      if (mounted) await showBayaError(context, message: '$error');
    }
  }

  TerminalTheme _theme(AppColors colors, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = dark ? TerminalThemes.defaultTheme : _lightAnsi;
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
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.bg,
        toolbarHeight: 52,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              info.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typo.title.copyWith(fontSize: 16),
            ),
            Text(
              '${info.address} · ${info.folder}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typo.monoSmall.copyWith(
                fontSize: 11,
                color: colors.muted,
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            key: const Key('terminal-menu'),
            icon: const Icon(LucideIcons.ellipsis, size: 20),
            onSelected: (choice) => switch (choice) {
              'bigger' => setState(
                () => _fontSize = (_fontSize + 1).clamp(8, 24),
              ),
              'smaller' => setState(
                () => _fontSize = (_fontSize - 1).clamp(8, 24),
              ),
              'paste' => unawaited(_paste()),
              _ => unawaited(_end()),
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'paste', child: Text(l10n.paste)),
              PopupMenuItem(value: 'bigger', child: Text(l10n.largerText)),
              PopupMenuItem(value: 'smaller', child: Text(l10n.smallerText)),
              if (_ended == null)
                PopupMenuItem(
                  value: 'end',
                  child: Text(
                    l10n.endTerminal,
                    style: TextStyle(color: colors.error),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _Notice(online: widget.online, ended: _ended, error: _error),
            Expanded(
              child: TerminalView(
                _terminal,
                key: ObjectKey(_terminal),
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                readOnly: _ended != null,
                theme: _theme(colors, Theme.of(context).brightness),
                keyboardAppearance: Theme.of(context).brightness,
                keyboardType: TextInputType.visiblePassword,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                textStyle: TerminalStyle(
                  fontSize: _fontSize,
                  fontFamily: kMonoFamily,
                ),
              ),
            ),
            if (_ended == null)
              _KeyBar(
                ctrl: _ctrl,
                alt: _alt,
                onCtrl: () => setState(() => _ctrl = !_ctrl),
                onAlt: () => setState(() => _alt = !_alt),
                onKey: _key,
                onText: _send,
              ),
          ],
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
                      fontSize: 13,
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
                ? Icon(icon, size: 17, color: on ? colors.bg : colors.text)
                : Text(
                    label,
                    style: context.typo.monoSmall.copyWith(
                      fontSize: 13,
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
