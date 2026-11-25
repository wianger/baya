/// The home, as Claude's: the menu in the corner, the mark and its name in
/// the middle, and a composer at the bottom that starts a session.
library;

import 'dart:async';

import 'package:app/data/launcher/launcher.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/workspace_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class SessionWelcome extends StatelessWidget {
  const SessionWelcome({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final menu = SessionShell.menuOf(context);
    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 68,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  if (menu != null)
                    CircleAction(
                      key: const Key('overview-menu'),
                      icon: LucideIcons.textAlignStart,
                      tooltip: context.l10n.openNavigation,
                      onPressed: menu,
                    ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Column(
                  key: const Key('workspace-overview'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Hero(tag: 'baya-mark', child: AppMark(size: 64)),
                    const SizedBox(height: 10),
                    Text(
                      kAppName,
                      key: const Key('overview-wordmark'),
                      style: brandDisplayTextStyle(
                        fontSize: 44,
                        color: colors.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const HomeComposer(),
          ],
        ),
      ),
    );
  }
}

/// A round, floating button: Claude's corner controls.
class CircleAction extends StatelessWidget {
  const CircleAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 52,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaSurface(
      role: BayaSurfaceRole.floating,
      radius: size / 2,
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(icon, size: 21, color: colors.text),
        ),
      ),
    );
  }
}

/// The home's composer: what is typed opens a new session and is sent to
/// it as its first message. The plus opens the new session's choices alone.
class HomeComposer extends StatefulWidget {
  const HomeComposer({super.key});

  @override
  State<HomeComposer> createState() => _HomeComposerState();
}

class _HomeComposerState extends State<HomeComposer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _start({String? prompt}) async {
    if (_starting) return;
    final home = context.read<HomeViewModel>();
    if (home.selectedWorkspace == null) {
      await showBayaNotice(
        context,
        title: context.l10n.noWorkspaceYet,
        message: context.l10n.createWorkspaceFirst,
      );
      return;
    }
    final shared = context.read<SharedDraft?>();
    setState(() => _starting = true);
    if (prompt != null) {
      unawaited(HapticFeedback.lightImpact());
      shared?.send(prompt);
    }
    try {
      final opened = await openNewSession(context);
      if (opened == null) {
        // Cancelled, or a parallel run: nothing takes the message.
        shared?.takePrompt();
      } else if (prompt != null) {
        _text.clear();
        _focus.unfocus();
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _send() {
    final text = _text.text.trim();
    if (text.isNotEmpty) unawaited(_start(prompt: text));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final hasText = _text.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: BayaSurface(
        key: const Key('home-composer'),
        role: BayaSurfaceRole.floating,
        radius: 28,
        emphasized: _focus.hasFocus,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _RoundButton(
                key: const Key('home-composer-new'),
                icon: LucideIcons.plus,
                tooltip: l10n.newSession,
                fill: colors.selection,
                color: colors.text,
                onPressed: _starting ? null : () => unawaited(_start()),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('home-composer-field'),
                  controller: _text,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: context.typo.sansBody.copyWith(fontSize: 16),
                  cursorColor: colors.accent,
                  decoration: InputDecoration(
                    hintText: l10n.homeComposerHint,
                    hintStyle: context.typo.sansBody.copyWith(
                      fontSize: 16,
                      color: colors.muted,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 11,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedOpacity(
                duration: BayaMotion.fast,
                opacity: hasText ? 1 : .35,
                child: _RoundButton(
                  key: const Key('home-composer-send'),
                  icon: LucideIcons.arrowUp,
                  tooltip: l10n.sendMessage,
                  fill: colors.text,
                  color: colors.bg,
                  onPressed: hasText && !_starting ? _send : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.fill,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color fill;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: fill,
      disabledBackgroundColor: fill,
      fixedSize: const Size.square(44),
      shape: const CircleBorder(),
    ),
    icon: Icon(icon, size: 20, color: color),
  );
}
