import 'dart:async';

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
    // Plan/24-fix-app-source-of-truth: render the lifecycle stage of
    // the bubble. `pending` (sent over WS, Pi hasn't echoed yet) gets
    // reduced opacity + a small spinner; `failed` (no echo in 15s) gets
    // a red exclamation badge so the user knows to retry.
    final isPending = message.status == UserMsgStatus.pending;
    final isFailed = message.status == UserMsgStatus.failed;
    final isSteering = message.steering;
    // Plan/30 — when an image is attached the bubble becomes an ImageBubble
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
// CompactionBubble — centered system card (plan/32)
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
    // Plan/32b — agent output is rendered as Markdown (GFM + code blocks),
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

/// Inline copy footer shown under the last assistant segment of a turn.
/// Rendered as a labelled row instead of a lone floating icon so the action
/// reads as belonging to the reply above it.
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
    return Align(
      alignment: Alignment.centerLeft,
      child: BayaGlassSurface(
        role: BayaGlassRole.control,
        radius: 18,
        elevated: false,
        child: Material(
          color: Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('assistant-copy'),
            onTap: _copy,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: BayaMotion.fast,
                    switchInCurve: BayaMotion.enter,
                    switchOutCurve: BayaMotion.exit,
                    child: Icon(
                      _copied ? LucideIcons.check : LucideIcons.copy,
                      key: ValueKey(_copied),
                      size: 14,
                      color: tint,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _copied ? 'Copied' : 'Copy',
                    style: context.typo.sansBody.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: tint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
