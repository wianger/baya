import 'package:app/data/preferences/preferences.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/value_objects/session_room.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_message_list.dart';
import 'package:app/ui/chat/commands/viewmodels/agent_commands_viewmodel.dart';
import 'package:app/ui/chat/context/widgets/context_usage_button.dart';
import 'package:app/ui/chat/context/widgets/context_usage_sheet.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:app/ui/chat/quick_actions/widgets/model_picker_sheet.dart';
import 'package:app/ui/chat/quick_actions/widgets/quick_actions_sheet.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/attach_sheet.dart';
import 'package:app/ui/chat/widgets/extension_ui_sheet.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
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
  /// Optional title hint passed via `go_router`
  /// `extra` from the Home tile. Used as the peer-label fallback in
  /// the AppBar so the user sees the right name *immediately* on
  /// navigation, instead of "—" / Baya until the PeerRecord
  /// is loaded by the ViewModel and the first `room_meta_updated`
  /// arrives.
  final String? initialTitle;

  /// The paired-computer label Home already knows, passed via
  /// `extra` / [SessionSelection]. Drives the AppBar's line 2 immediately so
  /// it never flickers empty/room-title while the PeerRecord loads async.
  /// When the PeerRecord arrives it resolves to the same string, so there's no
  /// visible change.
  final String? initialDevice;

  /// The live state of the tile Home tapped (its green dot). Seeds
  /// the AppBar status dot so it doesn't flash "reconnecting" before the VM
  /// reads the real runtime. Superseded by the live signal once it resolves
  /// ([ChatViewModel.connectionResolved]).
  final bool initialOnline;

  /// Plan/tablet — `false` when the chat is embedded as the tablet's
  /// detail pane (no navigation stack to pop back to). Hides the back
  /// arrow; defaults to `true` for the phone full-screen route.
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
    final vm = context.watch<ChatViewModel>();
    final quickActions = context.watch<QuickActionsViewModel>();
    final state = vm.state;

    final scaffold = Scaffold(
      backgroundColor: context.colors.bg,
      body: BayaBackdrop(
        child: SafeArea(
          bottom: false,
          child: ChatFrame(
            topBar: _buildTopBar(context, state),
            revoked: state is ChatReady && state.pairingRevoked
                ? _RevokedBanner(onRePair: () => context.go('/pair'))
                : null,
            body: _buildBody(context, state, vm),
            composer: _buildInput(context, state, vm, quickActions),
          ),
        ),
      ),
    );

    // An interactive extension_ui_request (ask_user via pi-ask)
    // renders as a full-screen modal layered ABOVE the Scaffold. Purely
    // reactive: the overlay leaves the tree when the pending request clears
    // (completed dismiss) — no route lifecycle to manage. `error` carries a
    // submit-result rejection so the modal can offer a retry instead of a dead
    // end.
    final ready = state is ChatReady ? state : null;
    final uiRequest = ready?.pendingUiRequest;
    if (uiRequest == null) return scaffold;
    return Stack(
      children: [
        scaffold,
        Positioned.fill(
          // Keyed by request id: a new flow must get a fresh State — question
          // ids repeat across flows (e.g. "goal"), so reusing the State would
          // leak old selections/custom text into the new modal.
          child: ExtensionUiSheet(
            key: ValueKey(uiRequest.id),
            request: uiRequest,
            error: ready?.pendingUiError,
            onRespond: vm.respondExtensionUi,
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(BuildContext context, ChatState state) {
    final colors = context.colors;
    final vm = context.watch<ChatViewModel>();
    final peer = vm.activePeer;
    final room = vm.activeRoom;
    final resolved = vm.connectionResolved;
    final online = resolved ? vm.isRoomLive : initialOnline;
    final reconnecting = resolved && state is ChatReady && state.isOffline;
    final working = vm.isWorking;
    final roomName = _roomDisplayName(room, state, initialTitle);
    final prefs = context.watch<Preferences>();
    final localName = peer != null && room != null
        ? prefs.sessionName(peer.remoteEpk, room.roomId)
        : null;
    final displayName = localName ?? roomName;
    final title = workspaceSessionTitle(displayName);
    final device = _peerDisplayName(peer, initialDevice);
    final statusColor = working
        ? colors.working
        : reconnecting
        ? colors.warning
        : online
        ? colors.success
        : colors.muted;
    final status = working
        ? context.l10n.statusWorking
        : reconnecting
        ? context.l10n.statusReconnecting
        : online
        ? context.l10n.statusReady
        : context.l10n.statusOffline;
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
            child: BayaGlassSurface(
              role: BayaGlassRole.control,
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
                      if (working) ...[
                        const SizedBox(width: 1),
                        Icon(
                          LucideIcons.pause,
                          size: 10.5,
                          color: colors.working,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          device,
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
            child: BayaGlassSurface(
              role: BayaGlassRole.control,
              radius: 25,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ContextUsageButton(
                    key: ValueKey('${peer?.remoteEpk}:${peer?.roomId}'),
                    enabled: online && peer != null,
                    working: working,
                    messageCount: state is ChatReady
                        ? state.messages.length
                        : 0,
                  ),
                  // Both header actions morph into the same anchored popover.
                  _HeaderActionAnchor(
                    builder: (origin) => IconButton(
                      key: const Key('chat-actions'),
                      tooltip: context.l10n.sessionActions,
                      onPressed: () => _openSessionActions(
                        context,
                        vm,
                        displayName,
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
    ChatViewModel vm,
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
        child: BayaGlassSurface(
          role: BayaGlassRole.overlay,
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
    await _handleSessionAction(context, vm, action, displayName);
  }

  Future<void> _handleSessionAction(
    BuildContext context,
    ChatViewModel vm,
    String value,
    String displayName,
  ) async {
    final currentPeer = vm.activePeer;
    if (currentPeer == null) return;
    final roomId = vm.activeRoom?.roomId ?? 'main';
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
        currentPeer.remoteEpk,
        roomId,
        name,
      );
      return;
    }
    if (value == 'info') {
      await showSessionInfoDialog(
        context,
        peer: currentPeer,
        room: vm.activeRoom,
        name: displayName,
      );
      return;
    }
    if (value != 'delete' || !context.mounted) return;
    final confirmed = await showSessionDeleteDialog(context, name: displayName);
    if (!confirmed || !context.mounted) return;
    final home = context.read<HomeViewModel>();
    for (final item in home.allItems) {
      if (item.peer.remoteEpk == currentPeer.remoteEpk &&
          item.room.roomId == roomId) {
        await home.deleteSession(item);
        if (!context.mounted) return;
        context.read<SessionSelection>().clear();
        context.go('/home');
        return;
      }
    }
    await showBayaError(context, message: context.l10n.sessionNotFoundToDelete);
  }

  static String _roomDisplayName(
    RoomInfo? room,
    ChatState state,
    String? initialTitle,
  ) {
    if (room != null) {
      final announced = displayRoomName(room.name);
      if (announced.isNotEmpty) return announced;
      final cwd = room.cwd;
      if (cwd != null && cwd.isNotEmpty) {
        final segs = cwd.split('/').where((s) => s.isNotEmpty).toList();
        if (segs.isNotEmpty) return segs.last;
      }
    }
    if (state is ChatReady && state.messages.isNotEmpty) {
      return _inferSessionName(state.messages);
    }
    // Home knows the peer label before /chat
    // mounts; use it instead of the generic kAppName placeholder
    // while we wait for the first room_meta_updated to populate
    // `room.name`.
    if (initialTitle != null && initialTitle.isNotEmpty) return initialTitle;
    return kAppName;
  }

  static String _peerDisplayName(PeerRecord? peer, String? fallback) {
    if (peer == null) {
      // While the ViewModel hasn't loaded the PeerRecord yet, fall
      // back to the device label Home passed (initialDevice) — same value the
      // PeerRecord resolves to, so no flicker on load.
      if (fallback != null && fallback.isNotEmpty) return fallback;
      return '—';
    }
    if (peer.nickname != null && peer.nickname!.isNotEmpty) {
      return peer.nickname!;
    }
    if (peer.sessionName.isNotEmpty) return peer.sessionName;
    return peer.remoteEpk.substring(0, 8);
  }

  Widget _buildBody(BuildContext context, ChatState state, ChatViewModel vm) {
    final hideToolCalls = context.watch<Preferences>().hideToolCalls;
    return switch (state) {
      // Edge case: opened /chat without a peer (e.g. peer revoked while
      // user was here). The chat is not the place to pair — render
      // a minimal empty state without an action. User navigates back
      // and uses Home / Settings → pairing.
      ChatNoPeer() => _EmptyState(
        icon: LucideIcons.messageCircle,
        message: context.l10n.noActiveDevice,
      ),
      ChatConnecting() => const _EmptyState(
        icon: LucideIcons.refreshCw,
        message: 'Connecting…',
      ),
      ChatFatalError(:final message) => _EmptyState(
        icon: LucideIcons.circleAlert,
        message: message,
        actionLabel: 'Re-pair',
        onAction: () => context.go('/pair'),
      ),
      ChatReady(:final messages, :final streaming) => () {
        final working = vm.isWorking;
        final visible = hideToolCalls
            ? messages
                  .where(
                    (m) =>
                        m is! ToolEvent ||
                        (m.status == ToolEventStatus.pending &&
                            m.args is Map &&
                            m.args['approval_required'] == true),
                  )
                  .toList()
            : messages;
        // Empty body → the default placeholder (Pi brand icon + "Nothing
        // here"), shown whenever there's nothing to render — including while
        // reconnecting (the reconnect handshake never swaps the body).
        if (visible.isEmpty && streaming == null && !working) {
          return _EmptyState(
            icon: LucideIcons.terminal,
            message: context.l10n.nothingHere,
          );
        }
        return ChatMessageList(
          key: const ValueKey('chat-message-list'),
          messages: visible,
          streaming: streaming,
          working: working,
          onDecide: (id, decision) => vm.approveTool(id, decision),
        );
      }(),
    };
  }

  Widget _buildInput(
    BuildContext context,
    ChatState state,
    ChatViewModel vm,
    QuickActionsViewModel quickActions,
  ) {
    final isReady = state is ChatReady;
    final isOffline = isReady && state.isOffline;
    final isRevoked = isReady && state.pairingRevoked;
    final isPeerOffline = isReady && state.peerOfflineReason != null;
    // Live relay-reported offline (no `bye`): Pi is just not reachable.
    final isPresenceOffline = isReady && state.peerPresence is PresenceOffline;
    // The composer is locked + the send button becomes "stop" for
    // the WHOLE working turn (send/echo → agent_done), not just the narrow
    // token-streaming window. Driven by the broad working signal so it matches
    // the AppBar/Home "working" indicator.
    final isWorking = isReady && vm.isWorking;
    final cancelId = vm.cancelTargetId;
    // Quick actions need an open channel to dispatch — only offer the
    // entry point when the chat input itself is enabled. Hiding the
    // ⚙ button on offline avoids a tap that would just throw inside
    // the sheet.
    final actionsEnabled =
        isReady &&
        !isOffline &&
        !isRevoked &&
        !isPeerOffline &&
        !isPresenceOffline;
    final commandState = context.watch<AgentCommandsViewModel>().state;

    return InputBar(
      key: const ValueKey('chat-floating-composer'),
      agentLabel: workspaceAgentLabelForRoom(
        vm.activeRoom?.name ?? initialTitle,
      ),
      modelLabel:
          quickActions.currentModelName ??
          vm.activeRoom?.model ??
          context.l10n.model,
      disabled:
          !isReady ||
          isOffline ||
          isRevoked ||
          isPeerOffline ||
          isPresenceOffline,
      streaming: isWorking,
      onCancel: cancelId != null ? () => vm.cancel(cancelId) : null,
      onOpenQuickActions: actionsEnabled
          ? () => showStandaloneModelPicker(context)
          : null,
      onSlashCommand: (id, raw) {
        switch (id) {
          case 'new':
            openNewSession(
              context,
              workspaceKey: context.read<HomeViewModel>().selectedWorkspace,
            );
          case 'model':
            showStandaloneModelPicker(context);
          case 'thinking':
            showQuickActionsSheet(context);
          case 'compact':
            showQuickActionsSheet(context, compactOnOpen: true);
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
            vm.sendMessage(raw);
          case 'workspace':
            showCreateWorkspace(context);
        }
      },
      onSlashOpen: context.read<AgentCommandsViewModel>().refresh,
      agentCommands: commandState.commands,
      agentCommandsLoading: commandState.loading,
      agentCommandsError: commandState.error,
      queuedMessages: isReady ? state.queuedMessages : const [],
      onSetQueued: vm.queueMessage,
      onClearQueued: vm.clearQueuedMessage,
      // Hold-to-talk voice input. The VM is route-scoped (bound in
      // app_router alongside ChatViewModel); InputBar listens to it directly,
      // so a read() is enough here.
      voice: context.read<VoiceInputViewModel>(),
      onVoiceHint: (hint) => _handleVoiceHint(context, hint),
      // Image attachments. takeImageForSend() reads + clears the
      // attached image so the inline image rides along with the (optionally
      // empty) caption. Attach-button gating by vision / already-attached is
      // internal to InputBar; the host only gates by channel availability.
      attachment: context.read<AttachmentViewModel>(),
      onOpenAttach: actionsEnabled
          ? () => _openAttach(context, context.read<AttachmentViewModel>())
          : null,
      onSend: (text) {
        final image = context.read<AttachmentViewModel>().takeImageForSend();
        vm.sendMessage(text, image: image);
      },
    );
  }

  /// Open the Camera/Gallery sheet and drive the picker. Hints deep-link to
  /// Settings after the async pick through the shared notice dialog.
  static Future<void> _openAttach(
    BuildContext context,
    AttachmentViewModel vm,
  ) async {
    final source = await showAttachSheet(context);
    if (source == null) return;
    AttachHint? hint;
    final sub = vm.hints.listen((h) => hint = h);
    switch (source) {
      case AttachSource.camera:
        await vm.pickFromCamera();
      case AttachSource.gallery:
        await vm.pickFromGallery();
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

  static String _inferSessionName(List<ChatMessage> msgs) {
    for (final m in msgs) {
      if (m is UserMsg) return m.text.substring(0, m.text.length.clamp(0, 32));
    }
    return kAppName;
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
            BayaGlassSurface(
              role: BayaGlassRole.content,
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
              BayaGlassButton(onPressed: onAction, label: Text(actionLabel!)),
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
