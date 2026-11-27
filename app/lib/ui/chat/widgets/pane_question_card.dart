/// When an agent in a herdr pane stops for an answer (a permission, a
/// choice), its question is shown above the composer as its TUI asks it,
/// with the keys that answer it: no trip to the terminal for a yes.
library;

import 'dart:async';

import 'package:app/data/hosts/host_connection.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07]*\x07');

/// A TUI's frame: borders and rules around what it asks.
final _frame = RegExp(
  r'^[\s│┃║|╭╮╰╯┌┐└┘├┤┬┴┼─━═╌╍┄┅]+|[\s│┃║|╭╮╰╯┌┐└┘├┤─━═]+$',
);
final _rule = RegExp(r'^[\s─━═╌╍┄┅\-_╭╮╰╯┌┐└┘│┃║]*$');

/// A choice as TUIs list them: `❯ 1. Yes`, `2) No`.
final _choice = RegExp(r'^(?:[❯›>▶●○◯◉*]\s*)?(\d)[.)]\s+(.+)$');

/// The question in a screen's text: its last lines, out of their frame.
@visibleForTesting
List<String> questionLines(String screen) {
  final lines = [
    for (final raw
        in screen.replaceAll(_ansi, '').replaceAll('\r', '').split('\n'))
      if (!_rule.hasMatch(raw)) raw.replaceAll(_frame, '').trimRight(),
  ].where((line) => line.trim().isNotEmpty).toList();
  return lines.skip(lines.length > 12 ? lines.length - 12 : 0).toList();
}

/// The numbered choices among [lines], as `(digit, label)`.
@visibleForTesting
List<(String, String)> questionChoices(List<String> lines) => [
  for (final line in lines)
    if (_choice.firstMatch(line.trim()) case final m?)
      (m.group(1)!, m.group(2)!.trim()),
];

class PaneQuestionCard extends StatefulWidget {
  const PaneQuestionCard({
    super.key,
    required this.host,
    required this.sessionId,
    required this.onOpenTerminal,
  });

  final HostConnection host;
  final String sessionId;
  final VoidCallback onOpenTerminal;

  @override
  State<PaneQuestionCard> createState() => _PaneQuestionCardState();
}

class _PaneQuestionCardState extends State<PaneQuestionCard> {
  List<String> _lines = const [];
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    _poll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_read()),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// The bottom of the pane's screen: where a TUI asks.
  Future<void> _read() async {
    try {
      final result = await widget.host.call('_baya/pane_screen', {
        'sessionId': widget.sessionId,
      });
      final lines = questionLines(result['text'] as String? ?? '');
      if (mounted && lines.join('\n') != _lines.join('\n')) {
        setState(() => _lines = lines);
      }
    } catch (_) {
      // Shown again on the next read.
    }
  }

  Future<void> _answer({String? text, List<String> keys = const []}) async {
    unawaited(HapticFeedback.selectionClick());
    await widget.host
        .call('_baya/pane_input', {
          'sessionId': widget.sessionId,
          'text': ?text,
          if (keys.isNotEmpty) 'keys': keys,
        })
        .catchError((Object _) => <String, dynamic>{});
    unawaited(Future<void>.delayed(const Duration(milliseconds: 300), _read));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final choices = questionChoices(_lines);
    final question = [
      for (final line in _lines)
        if (_choice.firstMatch(line.trim()) == null) line.trim(),
    ].join('\n');
    Widget answer(String label, VoidCallback onTap, {Key? key}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: OutlinedButton(
        key: key,
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 38),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: const StadiumBorder(),
        ),
        child: Text(label),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: BayaSurface(
        key: const Key('pane-question'),
        role: BayaSurfaceRole.floating,
        radius: 28,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.messageCircleQuestionMark,
                  size: 18,
                  color: colors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.paneWaitingForAnswer,
                    style: context.typo.sansBody.copyWith(
                      fontSize: BayaType.subhead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.sessionTerminal,
                  onPressed: widget.onOpenTerminal,
                  icon: const Icon(LucideIcons.squareTerminal, size: 18),
                ),
              ],
            ),
            if (question.isNotEmpty)
              Container(
                key: const Key('pane-question-text'),
                margin: const EdgeInsets.only(top: 6, bottom: 10),
                constraints: const BoxConstraints(maxHeight: 160),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.codeBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                // Wrapped to the card, the end (where it asks) in view.
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(
                    question,
                    style: context.typo.sansBody.copyWith(
                      fontSize: BayaType.footnote,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            // Its choices as it numbers them, each a tap.
            for (final (digit, label) in choices)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: OutlinedButton(
                  key: Key('pane-choice-$digit'),
                  onPressed: () => _answer(text: digit),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    '$digit. $label',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (choices.isEmpty) ...[
                    answer(
                      '1',
                      () => _answer(text: '1'),
                      key: const Key('pane-answer-1'),
                    ),
                    answer('2', () => _answer(text: '2')),
                    answer('3', () => _answer(text: '3')),
                  ],
                  answer('⏎', () => _answer(keys: ['enter'])),
                  answer('esc', () => _answer(keys: ['esc'])),
                  answer('↑', () => _answer(keys: ['up'])),
                  answer('↓', () => _answer(keys: ['down'])),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
