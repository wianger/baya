/// DeepSeek's long-press menu for an answer: a rounded card over a blurred
/// chat — copy, select text, read aloud, share.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:app/data/voice/read_aloud_controller.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

/// Markdown as plain words to read aloud: code blocks named, marks dropped.
String speechText(String markdown) => markdown
    .replaceAll(RegExp(r'```[\s\S]*?```'), ' code block ')
    .replaceAll(RegExp(r'[`*_>#~-]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String speechLanguage(String text) =>
    RegExp(r'[㐀-鿿]').hasMatch(text) ? 'zh-CN' : 'en-US';

enum _MessageAction { copy, select, read, share }

Future<void> showMessageMenu(BuildContext context, String markdown) async {
  unawaited(HapticFeedback.mediumImpact());
  final l10n = context.l10n;
  final action = await showGeneralDialog<_MessageAction>(
    context: context,
    barrierLabel: l10n.close,
    barrierColor: Colors.transparent,
    pageBuilder: (dialogContext, _, _) => const SizedBox.shrink(),
    transitionBuilder: (dialogContext, animation, _, _) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: BayaMotion.enter,
        reverseCurve: BayaMotion.exit,
      );
      Widget row(_MessageAction action, IconData icon, String label) => InkWell(
        key: ValueKey('message-menu-${action.name}'),
        onTap: () => Navigator.of(dialogContext).pop(action),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
          child: Row(
            children: [
              Icon(icon, size: 22, color: dialogContext.colors.text),
              const SizedBox(width: 18),
              Text(
                label,
                style: dialogContext.typo.sansBody.copyWith(fontSize: 17),
              ),
            ],
          ),
        ),
      );
      return Stack(
        children: [
          // The chat behind blurs as the card rises.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(dialogContext).pop(),
              child: AnimatedBuilder(
                animation: curved,
                builder: (_, _) => BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: 6 * curved.value,
                    sigmaY: 6 * curved.value,
                  ),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: .06 * curved.value),
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: .94, end: 1.0).animate(curved),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: BayaSurface(
                    key: const Key('message-menu'),
                    role: BayaSurfaceRole.floating,
                    radius: 32,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        row(_MessageAction.copy, LucideIcons.copy, l10n.copy),
                        row(
                          _MessageAction.select,
                          LucideIcons.textSelect,
                          l10n.selectText,
                        ),
                        row(
                          _MessageAction.read,
                          LucideIcons.volume2,
                          l10n.readAloud,
                        ),
                        row(
                          _MessageAction.share,
                          LucideIcons.forward,
                          l10n.share,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _MessageAction.copy:
      await Clipboard.setData(ClipboardData(text: markdown));
    case _MessageAction.select:
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => _SelectTextPage(markdown: markdown),
        ),
      );
    case _MessageAction.read:
      final text = speechText(markdown);
      if (text.isEmpty) return;
      await ReadAloudController.instance.toggle(
        owner: markdown,
        text: text,
        language: speechLanguage(text),
      );
    case _MessageAction.share:
      await SharePlus.instance.share(ShareParams(text: markdown));
  }
}

/// The answer on its own page, where its text can be selected.
class _SelectTextPage extends StatelessWidget {
  const _SelectTextPage({required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: BayaHeader(
        title: context.l10n.selectText,
        leading: HeaderLeading.close,
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('select-text-page'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [AgentMarkdown(markdown, selectable: true)],
        ),
      ),
    );
  }
}
