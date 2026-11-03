import 'package:app/data/hosts/session_controller.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/entities/agent_command.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_message_list.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/attach_sheet.dart';
import 'package:app/ui/chat/widgets/context_usage_button.dart';
import 'package:app/ui/chat/widgets/elicitation_card.dart';
import 'package:app/ui/chat/widgets/file_picker_sheet.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/chat/widgets/permission_card.dart';
import 'package:app/ui/chat/widgets/session_settings_sheet.dart';
import 'package:app/ui/chat/widgets/sign_in_card.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_top_right_popover.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_dialogs.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/workspace_navigation.dart';
import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

export 'package:app/ui/chat/chat_message_list.dart';

class ChatPage extends StatelessWidget {
  /// What the list already knew (title, computer, connected), so the header
  /// renders right away while the session loads.
  final String? initialTitle;
  final String? initialDevice;
  final bool initialOnline;

  /// `false` when the chat is the tablet's detail pane (nothing to pop to).
  final bool showBack;

  const ChatPage({
    super.key,
    this.initialTitle,
    this.initialDevice,
    this.initialOnline = false,
    this.showBack = true,
  });

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    // The agent's prompt capabilities decide whether images can be attached.
    final vision = session.loaded ? session.acceptsImages : null;
    final attachment = context.read<AttachmentViewModel>();
    if (attachment.state.visionSupported != vision) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => attachment.setVision(vision),
      );
    }
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: BayaBackdrop(
        child: SafeArea(
          bottom: false,
          child: ChatFrame(
            topBar: _buildTopBar(context, session),
            revoked: session.host.status.name == 'unpaired'
                ? _RevokedBanner(onRePair: () => context.go('/pair'))
                : null,
            body: _buildBody(context, session),
            composer: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (session.permission case final request?)
                  PermissionCard(
                    key: ValueKey('permission-${request.requestId}'),
                    request: request,
                    tool: session.messages
                        .whereType<ToolEvent>()
                        .where((t) => t.toolCallId == request.toolCall.id)
                        .lastOrNull,
                    onAnswer: session.answerPermission,
                  ),
                if (session.elicitation case final request?)
                  ElicitationCard(
                    key: ValueKey('elicitation-${request.requestId}'),
                    request: request,
                    onAnswer: session.answerElicitation,
                  ),
                if (session.authAgent != null)
                  SignInCard(
                    key: ValueKey('sign-in-${session.authAgent}'),
                    session: session,
                  ),
                if (session.attachedFiles.isNotEmpty)
                  _AttachedFiles(session: session),
                _buildInput(context, session),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, SessionController session) {
    final colors = context.colors;
    final online = session.online || (!session.loaded && initialOnline);
    final working = session.working;
    final prefs = context.watch<Preferences>();
    final localName = prefs.sessionName(session.host.key, session.sessionId);
    final title =
        localName ??
        (session.title.isNotEmpty ? session.title : initialTitle ?? kAppName);
    final device = session.host.host.label.isNotEmpty
        ? session.host.host.label
        : initialDevice ?? '—';
    final statusColor = working
        ? colors.working
        : online
        ? colors.success
        : colors.warning;
    final status = working
        ? context.l10n.statusWorking
        : online
        ? context.l10n.statusReady
        : context.l10n.statusReconnecting;
    final menu = SessionShell.menuOf(context);
    final leadingAction =
        menu ??
        (showBack
            ? () => context.canPop() ? context.pop() : context.go('/home')
            : null);
    return SizedBox(
      key: const ValueKey('chat-floating-header'),
      height: 58,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: BayaSurface(
              role: BayaSurfaceRole.control,
              radius: 25,
              padding: EdgeInsets.zero,
              child: SizedBox.square(
                dimension: 48,
                child: IconButton(
                  tooltip: menu != null
                      ? context.l10n.sessions
                      : context.l10n.back,
                  onPressed: leadingAction,
                  icon: Icon(
                    menu != null ? LucideIcons.menu : LucideIcons.chevronLeft,
                    size: 21,
                    color: colors.text,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 64),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.25,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          session.agentName.isEmpty
                              ? device
                              : '${session.agentName} · $device',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: colors.muted),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: statusColor,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        status,
                        style: TextStyle(fontSize: 10.5, color: statusColor),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: BayaSurface(
              role: BayaSurfaceRole.control,
              radius: 25,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ContextUsageButton(enabled: session.online),
                  _HeaderActionAnchor(
                    builder: (origin) => IconButton(
                      key: const Key('chat-actions'),
                      tooltip: context.l10n.sessionActions,
                      onPressed: () => _openSessionActions(
                        context,
                        session,
                        title,
                        origin: origin(),
                      ),
                      icon: Icon(
                        LucideIcons.ellipsis,
                        size: 21,
                        color: colors.muted2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSessionActions(
    BuildContext context,
    SessionController session,
    String displayName, {
    Rect? origin,
  }) async {
    final action = await showBayaTopRightPopover<String>(
      context: context,
      origin: origin,
      width: 224,
      surfaceRadius: 22,
      child: KeyedSubtree(
        key: const Key('session-actions-popover'),
        child: BayaSurface(
          role: BayaSurfaceRole.overlay,
          radius: 22,
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SessionActionTile(
                icon: LucideIcons.folderOpen,
                label: context.l10n.files,
                value: 'files',
              ),
              _SessionActionTile(
                icon: LucideIcons.pencil,
                label: context.l10n.rename,
                value: 'rename',
              ),
              _SessionActionTile(
                icon: LucideIcons.info,
                label: context.l10n.info,
                value: 'info',
              ),
              Divider(
                height: 1,
                thickness: 1,
                indent: 12,
                endIndent: 12,
                color: context.colors.border,
              ),
              _SessionActionTile(
                icon: LucideIcons.trash2,
                label: context.l10n.delete,
                value: 'delete',
                destructive: true,
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    await _handleSessionAction(context, session, action, displayName);
  }

  Future<void> _handleSessionAction(
    BuildContext context,
    SessionController session,
    String value,
    String displayName,
  ) async {
    final hostKey = session.host.key;
    if (value == 'files') {
      context.push('/session-files');
      return;
    }
    if (value == 'rename') {
      final name = await showSessionRenameDialog(
        context,
        currentName: displayName,
      );
      if (name == null || !context.mounted) return;
      await context.read<Preferences>().setSessionName(
        hostKey,
        session.sessionId,
        name,
      );
      return;
    }
    if (value == 'info') {
      await showSessionInfoDialog(
        context,
        peer: session.host.host,
        session: session.summary,
        name: displayName,
      );
      return;
    }
    if (value != 'delete' || !context.mounted) return;
    final confirmed = await showSessionDeleteDialog(context, name: displayName);
    if (!confirmed || !context.mounted) return;
    try {
      await session.host.call('session/delete', {
        'sessionId': session.sessionId,
      });
    } catch (error) {
      if (context.mounted) await showBayaError(context, message: '$error');
      return;
    }
    if (!context.mounted) return;
    context.read<SessionSelection>().clear();
    context.go('/home');
  }

  Widget _buildBody(BuildContext context, SessionController session) {
    final hideToolCalls = context.watch<Preferences>().hideToolCalls;
    final messages = session.messages;
    final working = session.working;
    if (messages.isEmpty && !working) {
      if (session.loading) {
        return const Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      final error = session.error;
      if (error != null) {
        return _EmptyState(
          icon: LucideIcons.circleAlert,
          message: error,
          actionLabel: context.l10n.retry,
          onAction: session.retry,
        );
      }
      return _EmptyState(
        icon: LucideIcons.terminal,
        message: session.online
            ? context.l10n.nothingHere
            : context.l10n.sessionOffline,
      );
    }
    final visible = hideToolCalls
        ? messages.where((m) => m is! ToolEvent || m.awaitingApproval).toList()
        : messages;
    return ChatMessageList(
      key: const ValueKey('chat-message-list'),
      messages: visible,
      working: working,
    );
  }

  Widget _buildInput(BuildContext context, SessionController session) {
    final online = session.online;
    final commands = session.commands;
    bool hasCommand(String name) => commands.any((c) => c.name == name);
    return InputBar(
      key: const ValueKey('chat-floating-composer'),
      agentLabel: session.agentName.isEmpty
          ? context.l10n.yourAgent
          : session.agentName,
      // The picker holds model, thinking and mode; its chip names the first
      // two.
      modelLabel: [
        session.configFor('model')?.current?.name,
        session.configFor('thought_level')?.current?.name,
      ].nonNulls.join(' · ').ifEmpty(context.l10n.settings),
      disabled: !online,
      streaming: session.working,
      onCancel: session.working ? session.cancel : null,
      onOpenQuickActions: online ? () => showSessionSettings(context) : null,
      onSlashCommand: (id, raw) {
        switch (id) {
          case 'new':
            openNewSession(
              context,
              workspaceKey: context.read<HomeViewModel>().selectedWorkspace,
            );
          case 'model':
            showSessionSettings(context, focus: 'model');
          case 'thinking':
            showSessionSettings(context, focus: 'thought_level');
          case 'compact':
            if (!hasCommand('compact')) {
              showBayaNotice(
                context,
                title: context.l10n.compactUnavailable,
                message: context.l10n.compactUnavailableHint,
              );
              return;
            }
            session.prompt('/compact');
          case 'context':
            showContextUsage(context);
          case 'attach':
            _openAttach(context, context.read<AttachmentViewModel>());
          case 'settings':
            context.push('/settings');
          case 'pair':
            context.push('/pair');
          case 'about':
            context.push('/about');
          case 'agent':
            session.prompt(raw);
          case 'workspace':
            showCreateWorkspace(context);
        }
      },
      agentCommands: [
        for (final command in commands)
          AgentCommand(
            name: command.name,
            source: 'agent',
            description: command.description,
          ),
      ],
      hiddenSlashCommandIds: hasCommand('compact')
          ? const {}
          : const {'compact'},
      voice: context.read<VoiceInputViewModel>(),
      onVoiceHint: (hint) => _handleVoiceHint(context, hint),
      attachment: context.read<AttachmentViewModel>(),
      onOpenAttach: online
          ? () => _openAttach(context, context.read<AttachmentViewModel>())
          : null,
      onSend: (text) {
        final image = context.read<AttachmentViewModel>().takeImageForSend();
        session.prompt(text, image: image);
      },
    );
  }

  /// Open the Camera/Gallery sheet and drive the picker. Hints deep-link to
  /// Settings after the async pick through the shared notice dialog.
  static Future<void> _openAttach(
    BuildContext context,
    AttachmentViewModel vm,
  ) async {
    final source = await showAttachSheet(
      context,
      images: !vm.state.attachBlockedByVision,
    );
    if (source == null) return;
    AttachHint? hint;
    final sub = vm.hints.listen((h) => hint = h);
    switch (source) {
      case AttachSource.camera:
        await vm.pickFromCamera();
      case AttachSource.gallery:
        await vm.pickFromGallery();
      case AttachSource.file:
        if (!context.mounted) return;
        return showFilePickerSheet(context, context.read<SessionController>());
    }
    await Future<void>.delayed(Duration.zero); // flush the hint microtask
    await sub.cancel();
    if (hint == null || !context.mounted) return;
    await _handleAttachHint(context, hint!);
  }

  static Future<void> _handleAttachHint(
    BuildContext context,
    AttachHint hint,
  ) async {
    switch (hint) {
      case AttachHint.cameraPermissionDenied:
        await showBayaNotice(
          context,
          title: context.l10n.cameraAccessOff,
          message: context.l10n.enableCameraInSettings,
          confirmLabel: context.l10n.openSettings,
          onConfirm: AppSettings.openAppSettings,
        );
      case AttachHint.pickFailed:
        await showBayaNotice(
          context,
          title: "Couldn't attach that image",
          message: context.l10n.tryPickingAgain,
        );
    }
  }

  /// Surfaces actionable voice failures through the shared notice dialog.
  /// The ordinary tap-to-learn gesture stays inside the composer as a
  /// transient tooltip.
  static void _handleVoiceHint(BuildContext context, VoiceHint hint) {
    switch (hint) {
      case VoiceHint.permissionDenied:
        showBayaNotice(
          context,
          title: context.l10n.microphoneAccessOff,
          message: context.l10n.enableMicrophoneInSettings,
          confirmLabel: context.l10n.openSettings,
          onConfirm: AppSettings.openAppSettings,
        );
    }
  }
}

/// Provides the exact square bounds of a header action at press time.
class _HeaderActionAnchor extends StatefulWidget {
  const _HeaderActionAnchor({required this.builder});

  final Widget Function(Rect? Function() origin) builder;

  @override
  State<_HeaderActionAnchor> createState() => _HeaderActionAnchorState();
}

class _HeaderActionAnchorState extends State<_HeaderActionAnchor> {
  final GlobalKey _boundsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      key: _boundsKey,
      dimension: 48,
      child: widget.builder(() {
        final anchor = _boundsKey.currentContext;
        return anchor == null ? null : bayaRectOf(anchor);
      }),
    );
  }
}

/// One row inside the session-action popover opened from the chat header.
class _SessionActionTile extends StatelessWidget {
  const _SessionActionTile({
    required this.icon,
    required this.label,
    required this.value,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tint = destructive ? colors.error : colors.text;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('session-action-$value'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.of(context).pop(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
          child: Row(
            children: [
              Icon(icon, size: 19, color: tint),
              const SizedBox(width: 14),
              Text(
                label,
                style: context.typo.sansBody.copyWith(
                  fontSize: 16,
                  color: tint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _EmptyState({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaReveal(
      offset: 10,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BayaSurface(
              role: BayaSurfaceRole.content,
              radius: 36,
              elevated: false,
              child: SizedBox.square(
                dimension: 72,
                child: Icon(icon, color: colors.muted, size: 30),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.typo.sansBody.copyWith(
                color: colors.muted,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 22),
              BayaButton(onPressed: onAction, label: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _RevokedBanner extends StatelessWidget {
  final VoidCallback onRePair;
  const _RevokedBanner({required this.onRePair});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.red.shade900.withValues(alpha: 0.85),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(LucideIcons.unlink, color: Colors.white, size: 15),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.pairingRevoked,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          GestureDetector(
            onTap: onRePair,
            child: const Text(
              'Re-pair',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Files from the computer that go with the next prompt.
class _AttachedFiles extends StatelessWidget {
  const _AttachedFiles({required this.session});
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final file in session.attachedFiles)
                InputChip(
                  key: ValueKey('attached-${file.uri}'),
                  avatar: Icon(
                    LucideIcons.fileText,
                    size: 15,
                    color: colors.muted2,
                  ),
                  label: Text(file.name, style: context.typo.monoSmall),
                  onDeleted: () => session.removeFile(file),
                  deleteIcon: const Icon(LucideIcons.x, size: 14),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
