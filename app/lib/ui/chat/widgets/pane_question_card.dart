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
  String _question = '';
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
      final lines = (result['text'] as String? ?? '')
          .replaceAll(_ansi, '')
          .replaceAll('\r', '')
          .split('\n')
          .map((line) => line.trimRight())
          .where((line) => line.trim().isNotEmpty)
          .toList();
      final question = lines
          .skip(lines.length > 10 ? lines.length - 10 : 0)
          .join('\n');
      if (mounted && question != _question) {
        setState(() => _question = question);
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
            if (_question.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 6, bottom: 10),
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.codeBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    _question,
                    style: context.typo.monoSmall.copyWith(
                      fontSize: BayaType.caption,
                    ),
                  ),
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  answer(
                    '1',
                    () => _answer(text: '1'),
                    key: const Key('pane-answer-1'),
                  ),
                  answer('2', () => _answer(text: '2')),
                  answer('3', () => _answer(text: '3')),
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
