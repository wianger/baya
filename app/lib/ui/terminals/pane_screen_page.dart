/// A session's terminal when its agent runs in a herdr pane: that pane's
/// screen, exactly as herdr shows it on the computer, drawn cell by cell at
/// the pane's own width and scaled to the phone (pinch to zoom). Keys and
/// text typed here go into the pane.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:app/data/hosts/host_connection.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/terminals/ghostty_view.dart';
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
    _screen.dispose();
    _line.dispose();
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

  Future<void> _input({String? text, List<String> keys = const []}) async {
    unawaited(HapticFeedback.selectionClick());
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
            // The pane at its width, fit to the phone; pinch for more.
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => InteractiveViewer(
                  maxScale: 4,
                  constrained: false,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: FittedBox(
                      fit: BoxFit.fitWidth,
                      alignment: Alignment.topLeft,
                      child: GhosttyView(
                        key: const Key('pane-screen'),
                        controller: _screen,
                        fontSize: 13,
                        fixed: true,
                        onResize: (_, _) {},
                      ),
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
                      onSubmitted: (_) => _submit(),
                      textInputAction: TextInputAction.send,
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
