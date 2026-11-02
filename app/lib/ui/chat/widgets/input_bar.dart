import 'dart:async';

import 'package:app/l10n/l10n.dart';

import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/entities/agent_command.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/voice/states/voice_input_state.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/voice/widgets/recording_strip.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// InputBar — bottom message composer.
// - Disabled (grayed) when offline.
// - During streaming, empty composer shows Stop; typed text sends steering.
// - The quiet model/thinking control stays available beside the
//   attach button while a draft or image is present.
// - When [voice] is provided, the mic becomes hold-to-talk:
//   long-press starts recording (a WhatsApp-style RecordingStrip replaces
//   the row), slide left past the threshold cancels, release transcribes
//   and drops the text into the (empty) field for manual review/send. The
//   recognizer never auto-sends.

/// One-shot UI hint the composer asks the host page to handle in Settings.
/// The lightweight hold-to-talk nudge stays local to the composer.
enum VoiceHint {
  /// Mic / speech permission was denied — guide to system Settings (#10).
  permissionDenied,
}

const _voiceTooltipDuration = Duration(milliseconds: 1200);

class InputBar extends StatefulWidget {
  final bool disabled; // offline or no peer
  final bool streaming; // show cancel instead of send
  final void Function(String text) onSend;
  final VoidCallback? onCancel;
  final VoidCallback? onOpenQuickActions;

  /// Slash-command palette selection. [id] is a built-in action; [raw] keeps
  /// the full `/text` so the host can forward unknown commands to the agent.
  final void Function(String id, String raw)? onSlashCommand;
  final VoidCallback? onSlashOpen;
  final List<AgentCommand> agentCommands;
  final bool agentCommandsLoading;
  final String? agentCommandsError;
  final VoidCallback? onStartAudio;
  final String agentLabel;
  final String modelLabel;

  /// Pi-side queued follow-ups. Empty means no queued messages.
  final List<QueuedMsg> queuedMessages;
  final void Function(String text)? onSetQueued;
  final void Function(String id)? onClearQueued;

  /// Voice-input ViewModel. When null the mic falls back to the
  /// legacy [onStartAudio] tap (and existing tests pump InputBar without it).
  final VoiceInputViewModel? voice;

  /// Surfaces actionable voice hints to the host page.
  final void Function(VoiceHint hint)? onVoiceHint;

  /// Image-attachment ViewModel (preview state + model vision).
  /// Null in tests / when attachments aren't wired.
  final AttachmentViewModel? attachment;

  /// Open the Camera/Gallery sheet. Null disables the attach
  /// button (offline/streaming); vision/has-image gating is internal.
  final VoidCallback? onOpenAttach;

  const InputBar({
    super.key,
    required this.onSend,
    this.onCancel,
    this.onOpenQuickActions,
    this.onSlashCommand,
    this.onSlashOpen,
    this.agentCommands = const [],
    this.agentCommandsLoading = false,
    this.agentCommandsError,
    this.onStartAudio,
    this.agentLabel = 'your agent',
    this.modelLabel = 'Session',
    this.queuedMessages = const [],
    this.onSetQueued,
    this.onClearQueued,
    this.voice,
    this.onVoiceHint,
    this.attachment,
    this.onOpenAttach,
    this.disabled = false,
    this.streaming = false,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  /// How far left the press must slide to arm slide-to-cancel (logical px).
  static const double _cancelThreshold = 90;

  final _controller = TextEditingController();
  // Owns the field's focus so we can intercept hardware Enter on its OWN
  // node (the primary/leaf focus). An ancestor Focus runs too late: the
  // FocusManager dispatches leaf→root, so the field's multiline newline
  // handling would consume Enter before an ancestor ever sees it.
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onComposerKey);
  bool _empty = true;
  bool _focused = false;
  String? _slashQuery;
  bool _cancelArmed = false;
  // True while the hold-to-talk gesture is active. Lets `_beginVoice` tell
  // whether the user is still holding once `startRecording` resolves — if not
  // (the permission prompt ended the hold), the recording is discarded.
  bool _holding = false;
  StreamSubscription<String>? _transcriptSub;
  final _voiceTooltipKey = GlobalKey<TooltipState>();
  Timer? _voiceTooltipTimer;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChange);
    _focusNode.addListener(_onFocusChange);
    _subscribeTranscripts();
  }

  void _onFocusChange() {
    if (!mounted || _focused == _focusNode.hasFocus) return;
    setState(() => _focused = _focusNode.hasFocus);
  }

  @override
  void didUpdateWidget(InputBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.voice, widget.voice)) {
      _transcriptSub?.cancel();
      _subscribeTranscripts();
    }
  }

  void _subscribeTranscripts() {
    _transcriptSub = widget.voice?.transcripts.listen(_onTranscript);
  }

  void _onTranscript(String text) {
    if (!mounted || text.isEmpty) return; // empty → no-op (#12)
    // Voice stays available while typing: append the transcript after any
    // existing draft instead of replacing the user's work.
    final existing = _controller.text.trimRight();
    final next = existing.isEmpty ? text : '$existing $text';
    _controller.text = next;
    _controller.selection = TextSelection.collapsed(offset: next.length);
  }

  void _onTextChange() {
    final text = _controller.text;
    final next = text.trim().isEmpty;
    final trimmed = text.trimLeft();
    final slash = trimmed.startsWith('/') && !trimmed.contains(' ')
        ? trimmed.substring(1).toLowerCase()
        : null;
    final enteredSlash = slash != null && _slashQuery == null;
    if (next == _empty && slash == _slashQuery) return;
    setState(() {
      _empty = next;
      _slashQuery = slash;
    });
    if (enteredSlash) widget.onSlashOpen?.call();
  }

  @override
  void dispose() {
    _transcriptSub?.cancel();
    _voiceTooltipTimer?.cancel();
    _controller.removeListener(_onTextChange);
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.disabled) return;
    final text = _controller.text.trim();
    // An attached image makes an empty-caption send valid.
    final hasImage = widget.attachment?.hasImage ?? false;
    if (text.isEmpty && !hasImage) return;
    _controller.clear();
    widget.onSend(text);
  }

  void _editQueued(QueuedMsg item) {
    if (!item.editable) return;
    widget.onClearQueued?.call(item.id);
    _controller.text = item.text;
    _controller.selection = TextSelection.collapsed(offset: item.text.length);
    _focusNode.requestFocus();
  }

  /// Hardware-keyboard behaviour (iPad keyboard case, etc.): plain Enter
  /// SENDS, Shift+Enter inserts a newline. On a touch soft-keyboard the
  /// newline arrives via `performAction` (not a key event), so this never
  /// fires there — the field keeps growing and the user sends with the
  /// composer button, exactly as before.
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    // Don't intercept while disabled, or mid-IME-composition (a CJK
    // candidate is confirmed with Enter, not sent) — let the field/IME deal.
    if (widget.disabled || !_controller.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+Enter → newline. Inserted explicitly (and consumed) so the
      // behaviour is identical on every platform instead of depending on
      // the framework's default multiline key handling.
      _insertNewlineAtCursor();
      return KeyEventResult.handled;
    }
    _submit();
    return KeyEventResult.handled;
  }

  /// Replaces the current selection (or inserts at the caret) with a newline
  /// and leaves the caret right after it.
  void _insertNewlineAtCursor() {
    final value = _controller.value;
    final sel = value.selection;
    if (!sel.isValid) {
      final text = '${value.text}\n';
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      return;
    }
    final text = '${sel.textBefore(value.text)}\n${sel.textAfter(value.text)}';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
  }

  // --- voice gesture ---------------------------------------------------------

  void _onVoiceStart() {
    _holding = true;
    if (_cancelArmed) setState(() => _cancelArmed = false);
    unawaited(_beginVoice());
  }

  Future<void> _beginVoice() async {
    final voice = widget.voice;
    if (voice == null) return;
    await voice.startRecording();
    if (!mounted) return;
    // Bug fix: on first use the OS permission prompt steals the hold — the
    // finger lifts to tap "Allow", so the press ends BEFORE recording actually
    // begins (state isn't VoiceRecording yet, so the release no-ops). When
    // `startRecording` then resolves and starts, the composer was left stuck
    // "recording" with no finger down. If the gesture is already over by the
    // time we get here, discard that phantom recording.
    if (!_holding && voice.state is VoiceRecording) {
      await voice.cancel();
      if (!mounted) return;
    }
    final s = voice.state;
    if (s is VoiceUnavailable &&
        s.reason == VoiceUnavailableReason.permissionDenied) {
      widget.onVoiceHint?.call(VoiceHint.permissionDenied);
    }
  }

  void _onVoiceMove(LongPressMoveUpdateDetails details) {
    if (widget.voice?.state is! VoiceRecording) return;
    final armed = details.offsetFromOrigin.dx < -_cancelThreshold;
    if (armed != _cancelArmed) setState(() => _cancelArmed = armed);
  }

  void _onVoiceEnd() {
    _holding = false;
    final voice = widget.voice;
    final armed = _cancelArmed;
    if (_cancelArmed) setState(() => _cancelArmed = false);
    if (voice == null || voice.state is! VoiceRecording) return;
    if (armed) {
      unawaited(voice.cancel());
    } else {
      // Transcript arrives via voice.transcripts → _onTranscript, the same
      // path the 60s cap uses — release never populates the field directly.
      unawaited(voice.stopAndTranscribe());
    }
  }

  void _onVoiceTap() {
    _voiceTooltipTimer?.cancel();
    _voiceTooltipKey.currentState?.ensureTooltipVisible();
    _voiceTooltipTimer = Timer(_voiceTooltipDuration, () {
      if (mounted) Tooltip.dismissAllToolTips();
    });
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      if (widget.voice != null) widget.voice!,
      if (widget.attachment != null) widget.attachment!,
    ];
    if (listenables.isEmpty) return _composer(context);
    // Rebuild on every voice/attachment emit (tick / level / availability /
    // pick) so the strip + preview animate even when no ancestor watches them.
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) => _composer(context),
    );
  }

  Widget _composer(BuildContext context) {
    final colors = context.colors;
    final voiceState = widget.voice?.state;
    final attachState = widget.attachment?.state;
    final canInteract = !widget.disabled;
    final hasQuickActions = widget.onOpenQuickActions != null;
    final recording = voiceState is VoiceRecording;
    final transcribing = voiceState is VoiceTranscribing;
    final showStrip = recording || transcribing;
    final voiceUnsupported =
        voiceState is VoiceUnavailable &&
        voiceState.reason == VoiceUnavailableReason.unsupported;

    // Attachment.
    final hasImage = attachState is AttachmentAttached;
    final visionBlocked = attachState?.attachBlockedByVision ?? false;
    final hasContent = !_empty || hasImage;
    final attachEnabled =
        widget.onOpenAttach != null &&
        canInteract &&
        !widget.streaming &&
        !showStrip &&
        !visionBlocked &&
        !hasImage;

    // Keep the model/thinking entry point reachable for the whole session.
    // A stale or slow working signal must not make the available catalogue
    // look empty by removing its only entry point.
    final showQuickActions = canInteract && !showStrip && hasQuickActions;

    // During a working turn with typed content, the main action sends steering;
    // keep a compact Stop affordance beside it so cancellation remains reachable.
    final showInlineStop =
        widget.streaming &&
        hasContent &&
        canInteract &&
        !showStrip &&
        widget.onCancel != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: BayaSurface(
        role: BayaSurfaceRole.overlay,
        radius: 28,
        emphasized: _focused,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_slashQuery != null && canInteract && !showStrip)
                    _SlashPalette(
                      query: _slashQuery!,
                      agentCommands: widget.agentCommands,
                      loading: widget.agentCommandsLoading,
                      error: widget.agentCommandsError,
                      onSelected: (id, raw) {
                        _controller.clear();
                        widget.onSlashCommand?.call(id, raw);
                      },
                    ),
                  if (hasImage)
                    _AttachmentPreview(
                      image: attachState.image,
                      onRemove: widget.attachment!.removeImage,
                    ),
                  for (final item in widget.queuedMessages)
                    _QueuedMessagePreview(
                      text: item.text,
                      editable: item.editable,
                      onTap: item.editable ? () => _editQueued(item) : null,
                      onClear: item.editable
                          ? () => widget.onClearQueued?.call(item.id)
                          : null,
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _AttachButton(
                        enabled: attachEnabled,
                        onTap: widget.onOpenAttach,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: TextField(
                          focusNode: _focusNode,
                          controller: _controller,
                          enabled: canInteract,
                          minLines: 1,
                          maxLines: 6,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          style: context.typo.sansBody.copyWith(fontSize: 16),
                          cursorColor: colors.accent,
                          decoration: InputDecoration(
                            hintText: widget.streaming
                                ? context.l10n.steerCurrentResponse
                                : (widget.voice != null ||
                                      widget.onStartAudio != null)
                                ? context.l10n.replyToAgentOrTalk(
                                    widget.agentLabel,
                                  )
                                : context.l10n.replyToAgent(widget.agentLabel),
                            hintStyle: context.typo.sansBody.copyWith(
                              color: colors.muted,
                            ),
                            filled: false,
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.fromLTRB(
                              2,
                              7,
                              4,
                              7,
                            ),
                          ),
                        ),
                      ),
                      if (!widget.streaming &&
                          !voiceUnsupported &&
                          (widget.voice != null ||
                              widget.onStartAudio != null)) ...[
                        _ComposerActionButton(
                          key: const ValueKey('voice-action'),
                          tooltipKey: _voiceTooltipKey,
                          audioOnly: true,
                          streaming: false,
                          hasContent: false,
                          disabled: widget.disabled,
                          onSendText: _submit,
                          onCancel: null,
                          onStartAudio: widget.onStartAudio,
                          voiceEnabled: widget.voice != null,
                          voiceUnsupported: voiceUnsupported,
                          onVoiceLongPressStart: _onVoiceStart,
                          onVoiceLongPressMoveUpdate: _onVoiceMove,
                          onVoiceLongPressEnd: _onVoiceEnd,
                          onVoiceTap: _onVoiceTap,
                        ),
                        const SizedBox(width: 3),
                      ],
                      _ComposerActionButton(
                        key: const ValueKey('message-action'),
                        streaming: widget.streaming,
                        hasContent: hasContent,
                        disabled: widget.disabled,
                        onSendText: _submit,
                        onCancel: widget.onCancel,
                        onStartAudio: widget.onStartAudio,
                        voiceEnabled: widget.voice != null,
                        voiceUnsupported: voiceUnsupported,
                        onVoiceLongPressStart: _onVoiceStart,
                        onVoiceLongPressMoveUpdate: _onVoiceMove,
                        onVoiceLongPressEnd: _onVoiceEnd,
                        onVoiceTap: _onVoiceTap,
                      ),
                      if (showInlineStop) ...[
                        const SizedBox(width: 3),
                        _InlineStopButton(onTap: widget.onCancel!),
                      ],
                    ],
                  ),
                  AnimatedSize(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : BayaMotion.standard,
                    curve: BayaMotion.enter,
                    alignment: Alignment.topCenter,
                    child: showQuickActions
                        ? Padding(
                            padding: const EdgeInsets.only(top: 7),
                            child: Center(
                              child: _QuickActionsButton(
                                show: true,
                                onPressed: widget.onOpenQuickActions,
                                label: widget.modelLabel,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            if (showStrip)
              Positioned.fill(
                child: IgnorePointer(
                  child: BayaSurface(
                    role: BayaSurfaceRole.content,
                    radius: 26,
                    elevated: false,
                    child: Center(
                      child: recording
                          ? RecordingStrip(
                              level: voiceState.level,
                              elapsed: voiceState.elapsed,
                              maxDuration:
                                  widget.voice?.maxDuration ??
                                  const Duration(seconds: 60),
                              cancelArmed: _cancelArmed,
                            )
                          : const _TranscribingStrip(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shows the message committed for auto-send after the current turn ends.
/// Tapping pulls it back into the composer for edit and cancels the pending
/// auto-send; X drops it.
class _QueuedMessagePreview extends StatelessWidget {
  const _QueuedMessagePreview({
    required this.text,
    required this.editable,
    this.onTap,
    this.onClear,
  });

  final String text;
  final bool editable;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('input-bar-queued-preview'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    LucideIcons.messageCircle,
                    size: 15,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        editable
                            ? context.l10n.queuedTapToEdit
                            : context.l10n.queuedFollowUp,
                        style: TextStyle(
                          color: colors.accent,
                          fontFamily: kMonoFamily,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontFamily: kMonoFamily,
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onClear != null) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      key: const Key('input-bar-clear-queued'),
                      tooltip: context.l10n.clearQueuedMessage,
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      splashRadius: 16,
                      onPressed: onClear,
                      icon: Icon(LucideIcons.x, color: colors.muted2),
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

/// Compact Stop affordance shown beside Send while steering text is typed.
class _InlineStopButton extends StatelessWidget {
  const _InlineStopButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      key: const Key('input-bar-inline-stop'),
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: colors.error.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(
            color: colors.error.withValues(alpha: 0.42),
            width: 0.6,
          ),
        ),
        child: Icon(LucideIcons.square300, color: colors.error, size: 17),
      ),
    );
  }
}

/// The attach (paperclip) button. Always visible; greyed + inert
/// when [enabled] is false (offline/streaming, a text-only model #9, or an
/// image is already attached).
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: enabled
          ? colors.selection
          : colors.surface.withValues(alpha: 0.44),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 34,
        height: 34,
        child: IconButton(
          key: const Key('input-bar-attach'),
          padding: EdgeInsets.zero,
          iconSize: 18,
          tooltip: context.l10n.attachImage,
          icon: Icon(
            LucideIcons.plus,
            color: enabled
                ? colors.accent
                : colors.muted.withValues(alpha: 0.35),
          ),
          onPressed: enabled ? onTap : null,
        ),
      ),
    );
  }
}

/// The composer image preview: a rounded thumbnail with an "X" to
/// discard before sending (decision #4).
class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.image, required this.onRemove});

  final PickedImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('attach-preview'),
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: SizedBox(
        width: 84,
        height: 84,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                image.bytes,
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
            Positioned(
              top: -4,
              right: 8,
              child: GestureDetector(
                key: const Key('attach-remove'),
                onTap: onRemove,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    shape: BoxShape.circle,
                    border: Border.all(color: context.colors.border),
                  ),
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    LucideIcons.x,
                    size: 13,
                    color: context.colors.text,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TranscribingStrip extends StatelessWidget {
  const _TranscribingStrip();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      key: const Key('transcribing-strip'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.accent,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'transcribing…',
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 12,
            color: colors.muted2,
          ),
        ),
      ],
    );
  }
}

class _QuickActionsButton extends StatefulWidget {
  const _QuickActionsButton({
    required this.show,
    required this.onPressed,
    required this.label,
  });

  final bool show;
  final VoidCallback? onPressed;
  final String label;

  @override
  State<_QuickActionsButton> createState() => _QuickActionsButtonState();
}

class _QuickActionsButtonState extends State<_QuickActionsButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeFactor;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: BayaMotion.emphasized,
      value: widget.show ? 1.0 : 0.0,
    );
    // Timeline (forward = appear): first grow [0.0–0.5], then fade in [0.5–1.0].
    // On reverse (disappear) the order flips → fade out first, then shrink.
    _sizeFactor = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: BayaMotion.enter),
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: BayaMotion.enter),
    );
  }

  @override
  void didUpdateWidget(covariant _QuickActionsButton old) {
    super.didUpdateWidget(old);
    if (widget.show == old.show) return;
    if (widget.show) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _sizeFactor,
      axis: Axis.horizontal,
      // -1.0 = start (centerLeft) — `alignment:` only exists on Flutter
      // ≥3.44 and breaks the 3.41 CI toolchain; drop the ignore once CI
      // moves to ≥3.44.
      // ignore: deprecated_member_use
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: _fade,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 190),
          // A filled pill with a chip icon and a caret makes it read as the
          // model switcher rather than a stray label next to `+`.
          child: BayaSurface(
            role: BayaSurfaceRole.card,
            radius: 20,
            elevated: false,
            child: Material(
              color: Colors.transparent,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const Key('input-bar-quick-actions'),
                onTap: widget.onPressed,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 9, 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        LucideIcons.chevronDown,
                        size: 14,
                        color: context.colors.muted2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ComposerMode { sendAudio, sendText, cancel }

class _ComposerActionButton extends StatelessWidget {
  const _ComposerActionButton({
    super.key,
    this.tooltipKey,
    this.audioOnly = false,
    required this.streaming,
    required this.hasContent,
    required this.disabled,
    required this.onSendText,
    required this.onCancel,
    required this.onStartAudio,
    required this.voiceEnabled,
    required this.voiceUnsupported,
    required this.onVoiceLongPressStart,
    required this.onVoiceLongPressMoveUpdate,
    required this.onVoiceLongPressEnd,
    required this.onVoiceTap,
  });

  final bool streaming;
  final bool audioOnly;
  final Key? tooltipKey;

  /// Text typed OR an image attached → the button is "send" (decision #6).
  final bool hasContent;
  final bool disabled;
  final VoidCallback onSendText;
  final VoidCallback? onCancel;
  final VoidCallback? onStartAudio;

  // Voice wiring.
  final bool voiceEnabled;
  final bool voiceUnsupported;
  final VoidCallback onVoiceLongPressStart;
  final void Function(LongPressMoveUpdateDetails) onVoiceLongPressMoveUpdate;
  final VoidCallback onVoiceLongPressEnd;
  final VoidCallback onVoiceTap;

  _ComposerMode get _mode {
    if (audioOnly) return _ComposerMode.sendAudio;
    if (streaming && !hasContent) return _ComposerMode.cancel;
    return _ComposerMode.sendText;
  }

  IconData get _icon {
    switch (_mode) {
      case _ComposerMode.cancel:
        return LucideIcons.square300;
      case _ComposerMode.sendText:
        return LucideIcons.arrowUp300;
      case _ComposerMode.sendAudio:
        return LucideIcons.mic300;
    }
  }

  VoidCallback? _resolveTap() {
    switch (_mode) {
      case _ComposerMode.cancel:
        return onCancel;
      case _ComposerMode.sendText:
        return disabled || !hasContent ? null : onSendText;
      case _ComposerMode.sendAudio:
        return disabled ? null : onStartAudio;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Decision #9 edge — no on-device recognition anywhere: hide the mic so
    // the empty field shows just the attach placeholder (dictate via keyboard).
    if (_mode == _ComposerMode.sendAudio && voiceUnsupported) {
      return const SizedBox.shrink();
    }

    final label = _mode == _ComposerMode.sendAudio
        ? context.l10n.voiceInput
        : _mode == _ComposerMode.cancel
        ? context.l10n.stopResponse
        : context.l10n.sendMessage;
    final voiceMode = _mode == _ComposerMode.sendAudio && voiceEnabled;
    return Semantics(
      button: true,
      label: label,
      enabled: _resolveTap() != null,
      child: Tooltip(
        key: tooltipKey,
        message: voiceMode ? context.l10n.holdToTalk : label,
        triggerMode: voiceMode
            ? TooltipTriggerMode.manual
            : TooltipTriggerMode.longPress,
        showDuration: voiceMode ? _voiceTooltipDuration : null,
        child: GestureDetector(
          key: _mode == _ComposerMode.sendAudio
              ? const Key('input-bar-voice')
              : const Key('input-bar-action'),
          onTap: voiceMode ? (disabled ? null : onVoiceTap) : _resolveTap(),
          onLongPressStart: voiceMode && !disabled
              ? (_) => onVoiceLongPressStart()
              : null,
          onLongPressMoveUpdate: voiceMode && !disabled
              ? onVoiceLongPressMoveUpdate
              : null,
          onLongPressEnd: voiceMode && !disabled
              ? (_) => onVoiceLongPressEnd()
              : null,
          child: _button(context),
        ),
      ),
    );
  }

  Widget _button(BuildContext context) {
    final colors = context.colors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final visualEnabled =
        !disabled && (_mode != _ComposerMode.sendText || hasContent);
    final isVoice = _mode == _ComposerMode.sendAudio;
    final isCancel = _mode == _ComposerMode.cancel;
    final background = !visualEnabled
        ? colors.inputFill
        : isCancel
        ? colors.error.withValues(alpha: .16)
        : isVoice
        ? colors.selection
        : colors.accent;
    final foreground = !visualEnabled
        ? colors.muted
        : isCancel
        ? colors.error
        : isVoice
        ? colors.text
        : colors.onAccent;
    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : BayaMotion.standard,
      curve: BayaMotion.enter,
      width: 42,
      height: 42,
      child: Center(
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : BayaMotion.standard,
          curve: BayaMotion.enter,
          // Both actions share one 38px circle so the pair reads as a set
          // instead of a small mic next to a large square send.
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
            border: Border.all(
              // Keep a hairline on the quiet states so the mic and the
              // (disabled) send read as a matching pair of circle buttons.
              color: visualEnabled
                  ? (isVoice ? colors.border : Colors.transparent)
                  : colors.border,
              width: 0.5,
            ),
            boxShadow:
                visualEnabled && !isVoice && !MediaQuery.highContrastOf(context)
                ? [
                    BoxShadow(
                      color: (isCancel ? colors.error : colors.accent)
                          .withValues(alpha: .20),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : BayaMotion.fast,
            switchInCurve: BayaMotion.enter,
            switchOutCurve: BayaMotion.exit,
            transitionBuilder: (child, anim) => reduceMotion
                ? child
                : FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: .82, end: 1).animate(anim),
                      child: child,
                    ),
                  ),
            child: Icon(
              _icon,
              key: ValueKey(_mode),
              color: foreground,
              // Lucide 300 matches the hairline weight used by native mobile
              // composer controls without making the glyph visually weak.
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

class _SlashCommand {
  const _SlashCommand(this.id, this.label, this.hint, this.icon);
  final String id;
  final String label;
  final String hint;
  final IconData icon;
}

class _SlashPalette extends StatelessWidget {
  const _SlashPalette({
    required this.query,
    required this.agentCommands,
    required this.loading,
    required this.error,
    required this.onSelected,
  });

  final String query;
  final List<AgentCommand> agentCommands;
  final bool loading;
  final String? error;
  final void Function(String id, String raw) onSelected;

  static final _commands = [
    _SlashCommand('new', appL10n.newSession, '/new', LucideIcons.squarePen),
    _SlashCommand(
      'workspace',
      appL10n.newWorkspace,
      '/workspace',
      LucideIcons.folderPlus,
    ),
    _SlashCommand('model', appL10n.switchModel, '/model', LucideIcons.cpu),
    _SlashCommand(
      'thinking',
      appL10n.thinkingLevel,
      '/thinking',
      LucideIcons.brain,
    ),
    _SlashCommand(
      'compact',
      appL10n.compactContext,
      '/compact',
      LucideIcons.shrink,
    ),
    _SlashCommand(
      'context',
      appL10n.contextUsage,
      '/context',
      LucideIcons.activity,
    ),
    _SlashCommand(
      'attach',
      appL10n.attachImage,
      '/attach',
      LucideIcons.paperclip,
    ),
    _SlashCommand(
      'settings',
      appL10n.settings,
      '/settings',
      LucideIcons.settings2,
    ),
    _SlashCommand('pair', appL10n.pairComputer, '/pair', LucideIcons.scanLine),
    _SlashCommand('about', appL10n.about, '/about', LucideIcons.info),
  ];

  @override
  Widget build(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final matches = _commands
        .where(
          (c) =>
              normalized.isEmpty ||
              c.id.startsWith(normalized) ||
              c.label.toLowerCase().contains(normalized),
        )
        .toList();
    final agentMatches = agentCommands
        .where(
          (command) =>
              normalized.isEmpty ||
              command.name.toLowerCase().startsWith(normalized) ||
              command.description.toLowerCase().contains(normalized),
        )
        .toList();
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 268),
        child: BayaSurface(
          key: const Key('slash-command-palette'),
          role: BayaSurfaceRole.overlay,
          radius: 18,
          elevated: false,
          child: Material(
            type: MaterialType.transparency,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final command in matches)
                  ListTile(
                    dense: true,
                    leading: Icon(command.icon, size: 17, color: colors.muted2),
                    title: Text(
                      command.label,
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      command.hint,
                      style: context.typo.monoSmall.copyWith(
                        color: colors.muted,
                      ),
                    ),
                    onTap: () => onSelected(command.id, command.hint),
                  ),
                if (agentMatches.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Text(
                      context.l10n.agentCommandsSkills,
                      style: context.typo.sansBody.copyWith(
                        color: colors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final command in agentMatches)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        command.source == 'skill'
                            ? LucideIcons.sparkles
                            : LucideIcons.terminal,
                        size: 17,
                        color: colors.accent,
                      ),
                      title: Text(
                        '/${command.name}',
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        command.description.isEmpty
                            ? _sourceLabel(command.source)
                            : '${_sourceLabel(command.source)} · ${command.description}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          color: colors.muted,
                          fontSize: 11,
                        ),
                      ),
                      onTap: () => onSelected('agent', '/${command.name}'),
                    ),
                ] else if (loading)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: Text(
                      error!,
                      style: context.typo.sansBody.copyWith(
                        color: colors.error,
                        fontSize: 11,
                      ),
                    ),
                  ),
                Divider(height: 1, color: colors.border),
                ListTile(
                  dense: true,
                  leading: Icon(
                    LucideIcons.terminal,
                    size: 17,
                    color: colors.accent,
                  ),
                  title: Text(
                    normalized.isEmpty
                        ? context.l10n.sendSlashCommand
                        : context.l10n.sendCommandToAgent(normalized),
                    style: const TextStyle(fontSize: 13),
                  ),
                  onTap: () => onSelected('agent', '/$normalized'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _sourceLabel(String source) => switch (source) {
    'skill' => appL10n.skill,
    'prompt' => appL10n.prompt,
    _ => appL10n.agentCommand,
  };
}
