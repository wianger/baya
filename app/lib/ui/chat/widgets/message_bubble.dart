import 'package:app/acp/acp.dart';

import 'dart:async';

import 'package:app/l10n/l10n.dart';

import 'package:app/data/voice/read_aloud_controller.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
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
    // Pending = sent, not started yet (in transit or queued behind a turn).
    final isPending = message.status == UserMsgStatus.pending;
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
                    ? ImageBubble(image: image, caption: message.text)
                    : BayaSurface(
                        role: BayaSurfaceRole.user,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(22),
                          topRight: Radius.circular(22),
                          bottomLeft: Radius.circular(22),
                          bottomRight: Radius.circular(7),
                        ),
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
              if (isPending)
                Padding(
                  padding: const EdgeInsets.only(top: 5, right: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                        context.l10n.queued,
                        style: typo.sansBody.copyWith(
                          color: colors.muted,
                          fontSize: 11,
                        ),
                      ),
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

/// A system card: the agent compacted its context, with its summary.
class CompactionBubble extends StatelessWidget {
  final CompactionMsg message;
  const CompactionBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final summary = message.summary;
    final colors = context.colors;
    return BayaReveal(
      offset: 5,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: BayaSurface(
            role: BayaSurfaceRole.content,
            radius: 15,
            elevated: false,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    message.done
                        ? Icon(
                            LucideIcons.check,
                            size: 14,
                            color: colors.success,
                          )
                        : SizedBox.square(
                            dimension: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.4,
                              color: colors.muted,
                            ),
                          ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        message.done
                            ? context.l10n.contextCompacted
                            : context.l10n.compacting,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 13,
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                        ),
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
// NoticeBubble / PlanCard — what the agent or Baya wants the user to know
// ---------------------------------------------------------------------------

class NoticeBubble extends StatelessWidget {
  final NoticeMsg message;
  const NoticeBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (icon, tint) = switch (message.severity) {
      'error' => (LucideIcons.circleAlert, colors.error),
      'warning' => (LucideIcons.triangleAlert, colors.warning),
      _ => (LucideIcons.info, colors.muted2),
    };
    return BayaReveal(
      offset: 5,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 14, color: tint),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: SelectableText(
                    message.text,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 13,
                      height: 1.4,
                      color: tint,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlanCard extends StatelessWidget {
  final PlanMsg message;
  const PlanCard(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaReveal(
      offset: 5,
      child: BayaSurface(
        role: BayaSurfaceRole.content,
        radius: 18,
        elevated: false,
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.plan,
              style: context.typo.sansBody.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 6),
            for (final entry in message.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        switch (entry.status) {
                          PlanStatus.completed => LucideIcons.circleCheck,
                          PlanStatus.inProgress => LucideIcons.circleDot,
                          PlanStatus.pending => LucideIcons.circle,
                        },
                        size: 14,
                        color: switch (entry.status) {
                          PlanStatus.completed => colors.success,
                          PlanStatus.inProgress => colors.working,
                          PlanStatus.pending => colors.muted,
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.content,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 13.5,
                          height: 1.4,
                          color: entry.status == PlanStatus.completed
                              ? colors.muted
                              : colors.text,
                          decoration: entry.status == PlanStatus.completed
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
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
            tooltip: _copied ? context.l10n.copied : context.l10n.copy,
            onPressed: _copy,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
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
            tooltip: speaking
                ? context.l10n.stopReading
                : context.l10n.readAloud,
            onPressed: _toggle,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
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
