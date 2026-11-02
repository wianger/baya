import 'dart:async';

import 'package:app/data/voice/read_aloud_controller.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ---------------------------------------------------------------------------
// UserBubble — right-aligned dark card
// ---------------------------------------------------------------------------

class UserBubble extends StatelessWidget {
  final UserMsg message;
  const UserBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    // Render the lifecycle stage of
    // the bubble. `pending` (sent over WS, Pi hasn't echoed yet) gets
    // reduced opacity + a small spinner; `failed` (no echo in 15s) gets
    // a red exclamation badge so the user knows to retry.
    final isPending = message.status == UserMsgStatus.pending;
    final isFailed = message.status == UserMsgStatus.failed;
    final isSteering = message.steering;
    // When an image is attached the bubble becomes an ImageBubble
    // (thumbnail + caption); otherwise the existing text card.
    final image = message.image;
    final colors = context.colors;
    final typo = context.typo;
    return BayaReveal(
      offset: 7,
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AnimatedOpacity(
                opacity: isPending ? 0.64 : 1,
                duration: BayaMotion.fast,
                curve: BayaMotion.enter,
                child: image != null
                    ? ImageBubble(
                        image: image,
                        caption: message.text,
                        isFailed: isFailed,
                      )
                    : BayaGlassSurface(
                        role: BayaGlassRole.user,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(22),
                          topRight: Radius.circular(22),
                          bottomLeft: Radius.circular(22),
                          bottomRight: Radius.circular(7),
                        ),
                        emphasized: isFailed,
                        emphasisColor: isFailed ? colors.error : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          // Selectable so the user can copy their own message.
                          child: SelectableText(
                            message.text,
                            style: typo.sansBody.copyWith(
                              color: colors.onUserBubble,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
              ),
              if (isPending || isSteering || isFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 5, right: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPending || isSteering) ...[
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            color: colors.muted,
                            strokeWidth: 1.2,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isSteering ? 'steering…' : 'sending…',
                          style: typo.sansBody.copyWith(
                            color: colors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ] else ...[
                        Icon(
                          LucideIcons.circleAlert,
                          size: 12,
                          color: colors.error,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'not delivered',
                          style: typo.sansBody.copyWith(
                            color: colors.error,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CompactionBubble — centered system card
// ---------------------------------------------------------------------------

/// A system message distinct from user/assistant: shows that the Pi compacted
/// the context, with the recap summary and the reclaimed token count. Mirrors
/// the TUI's CompactionSummaryMessageComponent.
class CompactionBubble extends StatelessWidget {
  final CompactionMsg message;
  const CompactionBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = message.tokensBefore;
    final summary = message.summary;
    final colors = context.colors;
    return BayaReveal(
      offset: 5,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: BayaGlassSurface(
            role: BayaGlassRole.content,
            radius: 15,
            elevated: false,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.check, size: 14, color: colors.success),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Context compacted',
                        style: context.typo.sansBody.copyWith(
                          fontSize: 13,
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (tokens != null)
                      Text(
                        '~$tokens tokens',
                        style: TextStyle(
                          fontFamily: kMonoFamily,
                          fontSize: 11,
                          color: colors.muted,
                        ),
                      ),
                  ],
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    summary,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 13,
                      height: 1.45,
                      color: colors.muted2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AssistantBubble — left-aligned monospace text
// ---------------------------------------------------------------------------

class AssistantBubble extends StatelessWidget {
  final AssistantMsg message;
  final bool showCopy;
  const AssistantBubble(this.message, {super.key, this.showCopy = true});

  @override
  Widget build(BuildContext context) {
    // Agent output is rendered as Markdown (GFM + code blocks),
    // spanning the FULL content width (the message list already pads 16px on
    // each side) — unlike the user's right-aligned chat bubble, which stays
    // capped. Selectable so prose/code can be copied.
    return BayaReveal(
      offset: 9,
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AgentMarkdown(message.text, selectable: true),
            if (showCopy) ...[
              const SizedBox(height: 8),
              _CopyRow(text: message.text),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact action row shown under the final assistant segment of a turn.
///
/// Claude's mobile transcript keeps these controls quiet and icon-led. The
/// label remains available to screen readers and tooltips, while the visual
/// footprint stays small enough not to interrupt the reading rhythm.
class _CopyRow extends StatefulWidget {
  const _CopyRow({required this.text});

  final String text;

  @override
  State<_CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<_CopyRow> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tint = _copied ? colors.accent : colors.muted2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            key: const Key('assistant-copy'),
            tooltip: _copied ? 'Copied' : 'Copy',
            onPressed: _copy,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            icon: AnimatedSwitcher(
              duration: BayaMotion.fast,
              switchInCurve: BayaMotion.enter,
              switchOutCurve: BayaMotion.exit,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: Icon(
                _copied ? LucideIcons.check : LucideIcons.copy,
                key: ValueKey(_copied),
                size: 15,
                color: tint,
              ),
            ),
          ),
        ),
        _ReadAloudButton(text: widget.text),
      ],
    );
  }
}

class _ReadAloudButton extends StatefulWidget {
  const _ReadAloudButton({required this.text});

  final String text;

  @override
  State<_ReadAloudButton> createState() => _ReadAloudButtonState();
}

class _ReadAloudButtonState extends State<_ReadAloudButton> {
  Future<void> _toggle() async {
    final text = _speechText(widget.text);
    if (text.isEmpty) return;
    await ReadAloudController.instance.toggle(
      owner: this,
      text: text,
      language: _languageFor(text),
    );
  }

  @override
  void dispose() {
    unawaited(ReadAloudController.instance.stopFor(this));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final readAloud = ReadAloudController.instance;
    return ListenableBuilder(
      listenable: readAloud,
      builder: (context, _) {
        final speaking = readAloud.isSpeakingFor(this);
        return Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            key: const Key('assistant-speak'),
            tooltip: speaking ? 'Stop reading' : 'Read aloud',
            onPressed: _toggle,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            icon: AnimatedSwitcher(
              duration: BayaMotion.fast,
              switchInCurve: BayaMotion.enter,
              switchOutCurve: BayaMotion.exit,
              child: Icon(
                speaking ? LucideIcons.volumeX : LucideIcons.volume2,
                key: ValueKey(speaking),
                size: 15,
                color: speaking ? colors.accent : colors.muted2,
              ),
            ),
          ),
        );
      },
    );
  }

  static String _speechText(String markdown) => markdown
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' code block ')
      .replaceAll(RegExp(r'[`*_>#~-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _languageFor(String text) {
    final hasCjk = RegExp(r'[\u3400-\u9fff]').hasMatch(text);
    return hasCjk ? 'zh-CN' : 'en-US';
  }
}
