/// The chat transcript: tool-run grouping, the floating-composer frame and
/// the scrolling message list.
library;

import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/startup_note.dart';
import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:app/ui/chat/widgets/tool_run_group.dart';
import 'package:app/ui/chat/widgets/working_indicator.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Groups chat messages for rendering: consecutive completed tool calls become
/// a single [ToolRunItem]; everything else stays in order.
List<Object> toolRunItemsForMessages(List<ChatMessage> messages) {
  final items = <Object>[];
  final run = <ToolEvent>[];
  void flushRun() {
    if (run.isEmpty) return;
    items.add(run.length == 1 ? run.single : ToolRunItem(List.of(run)));
    run.clear();
  }

  for (final message in messages) {
    // Empty agent text (some agents open a turn with an empty chunk) has
    // nothing to show.
    if (message is AssistantMsg && message.text.trim().isEmpty) continue;
    // The computer marks what an agent says on its own before the first
    // prompt (version, loaded skills): startup chatter, not a reply.
    if (message is AssistantMsg && message.startup) {
      flushRun();
      items.add(StartupNote(message));
      continue;
    }
    if (message is ToolEvent && !message.awaitingApproval) {
      run.add(message);
      continue;
    }
    flushRun();
    items.add(message);
  }
  flushRun();
  return items;
}

/// An agent message sent before the first prompt.
class StartupNote {
  const StartupNote(this.message);
  final AssistantMsg message;
}

/// A run of consecutive tool calls rendered as one collapsible row.
class ToolRunItem {
  const ToolRunItem(this.tools);
  final List<ToolEvent> tools;
}

/// Returns the final assistant segment object of each completed user turn.
///
/// Tool and thinking boundaries split one logical answer across several
/// bubbles. The result uses identity equality so segments are told apart
/// even when ids repeat.
/// The reply of each finished turn: the last assistant segment before the
/// next prompt. While [working], the newest turn is still being written and
/// gets none, so copy and read-aloud never offer half an answer.
Set<AssistantMsg> assistantCopyOwnersForTurns(
  List<ChatMessage> messages, {
  bool working = false,
}) {
  final owners = Set<AssistantMsg>.identity();
  AssistantMsg? lastAssistant;

  void finishTurn() {
    if (lastAssistant != null) owners.add(lastAssistant!);
    lastAssistant = null;
  }

  for (final message in messages) {
    if (message is AssistantMsg) {
      lastAssistant = message;
      continue;
    }
    if (message is UserMsg) finishTurn();
  }
  if (!working) finishTurn();
  return owners;
}

/// Composer height published to the transcript.
///
/// The transcript keeps scrolling *under* the floating composer, so anything
/// anchored to its bottom has to know how tall the composer currently is. It
/// grows with an attachment preview, queued-message previews, the slash
/// palette and multi-line text, so a constant inset cannot stay correct.
class _ComposerHeight extends InheritedNotifier<ValueNotifier<double>> {
  const _ComposerHeight({
    required ValueNotifier<double> notifier,
    required super.child,
  }) : super(notifier: notifier);

  /// Current composer height, or 0 before the first measurement.
  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ComposerHeight>()
          ?.notifier
          ?.value ??
      0;
}

/// Chat body + top bar + floating composer, measuring the composer as it
/// changes so the transcript and its jump-to-latest control stay clear of it.
class ChatFrame extends StatefulWidget {
  const ChatFrame({
    super.key,
    required this.topBar,
    required this.revoked,
    required this.body,
    required this.composer,
  });

  final Widget topBar;
  final Widget? revoked;
  final Widget body;
  final Widget composer;

  @override
  State<ChatFrame> createState() => _ChatFrameState();
}

class _ChatFrameState extends State<ChatFrame> {
  final _composerHeight = ValueNotifier<double>(0);
  final _composerKey = GlobalKey();

  @override
  void dispose() {
    _composerHeight.dispose();
    super.dispose();
  }

  /// Reads the laid-out composer size once per frame. Only the notifier moves,
  /// so dependents rebuild without re-entering this widget's build.
  void _measureComposer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final height = _composerKey.currentContext?.size?.height;
      if (height == null) return;
      if ((height - _composerHeight.value).abs() < 0.5) return;
      _composerHeight.value = height;
    });
  }

  @override
  Widget build(BuildContext context) {
    _measureComposer();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: _ComposerHeight(notifier: _composerHeight, child: widget.body),
        ),
        // The transcript scrolls under the floating header; a fade to the
        // page colour keeps the title readable over it.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 88,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, .62, 1],
                  colors: [
                    context.colors.bg,
                    context.colors.bg.withValues(alpha: .92),
                    context.colors.bg.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(top: 8, left: 12, right: 12, child: widget.topBar),
        if (widget.revoked != null)
          Positioned(top: 78, left: 12, right: 12, child: widget.revoked!),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            key: _composerKey,
            top: false,
            child: widget.composer,
          ),
        ),
      ],
    );
  }
}

class ChatMessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool working;

  /// The history has loaded: rows that appear from now on arrive live and
  /// animate in, once each.
  final bool live;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.working,
    this.live = true,
  });

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  /// How far past the newest message the user must scroll before the
  /// "jump to latest" button appears. Small on purpose so it shows up as soon
  /// as the newest message leaves the viewport.
  static const _latestThreshold = 72.0;

  final _controller = ScrollController();
  bool _showLatest = false;
  bool _keyboardDismissTriggered = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final next = _isAwayFromLatest(_controller.position);
    if (next == _showLatest) return;
    setState(() => _showLatest = next);
  }

  /// `reverse: true` anchors the newest row at scroll offset 0, so
  /// `extentBefore` is exactly how far the user has travelled back into the
  /// history. That stays correct when a single message is taller than the
  /// viewport, where a plain offset threshold can be reached instantly.
  bool _isAwayFromLatest(ScrollMetrics metrics) {
    if (metrics.maxScrollExtent <= 0) return false;
    return metrics.extentBefore > _latestThreshold;
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _keyboardDismissTriggered = false;
    }
    if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      if (!_keyboardDismissTriggered) {
        _keyboardDismissTriggered = true;
        FocusManager.instance.primaryFocus?.unfocus();
      }
    }
    if (notification is ScrollEndNotification) {
      _keyboardDismissTriggered = false;
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification ||
        notification is UserScrollNotification) {
      final next = _isAwayFromLatest(notification.metrics);
      if (next != _showLatest) setState(() => _showLatest = next);
    }
    return false;
  }

  Future<void> _jumpToLatest() async {
    if (!_controller.hasClients) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await _controller.animateTo(
      0,
      duration: BayaMotion.scroll,
      curve: BayaMotion.enter,
    );
  }

  // Grouping, copy buttons and each message's widget are worked out again
  // only when the transcript changes; a streamed chunk then rebuilds the one
  // message it touched, not every visible bubble.
  List<ChatMessage>? _seen;
  bool _seenWorking = false;
  List<Object> _items = const [];
  Set<AssistantMsg> _copyOwners = const {};
  final _built = Map<ChatMessage, (bool, Widget)>.identity();

  void _refresh() {
    final messages = widget.messages;
    if (identical(messages, _seen) && widget.working == _seenWorking) return;
    _seenWorking = widget.working;
    _seen = messages;
    _items = toolRunItemsForMessages(messages);
    _copyOwners = assistantCopyOwnersForTurns(
      messages,
      working: widget.working,
    );
    final live = Set<ChatMessage>.identity()..addAll(messages);
    _built.removeWhere((message, _) => !live.contains(message));
  }

  // Rows already on screen, or in the history when it loaded, never animate
  // in again.
  final _shown = <Object>{};
  bool _wasLive = false;

  static Object _rowKey(Object item) => switch (item) {
    ToolRunItem(:final tools) => tools.first.id,
    StartupNote(:final message) => message.id,
    ToolEvent(:final toolCallId) => toolCallId,
    ChatMessage(:final id) => id,
    _ => item,
  };

  void _settle() {
    if (!widget.live) {
      _wasLive = false;
    } else if (!_wasLive) {
      _wasLive = true;
      _shown.addAll(_items.map(_rowKey));
    }
  }

  Widget _once(ChatMessage message, bool flag, Widget Function() build) {
    final hit = _built[message];
    if (hit != null && hit.$1 == flag) return hit.$2;
    final widget = build();
    _built[message] = (flag, widget);
    return widget;
  }

  @override
  Widget build(BuildContext context) {
    _refresh();
    _settle();
    final items = _items;
    // While a turn runs, a quiet row at the newest position says so, also
    // under text already written: the agent may be thinking or about to call
    // a tool, with nothing new to show for a while.
    final showWorkingIndicator = widget.working;
    final leadingRows = showWorkingIndicator ? 1 : 0;
    final itemCount = items.length + leadingRows;
    // One copy action per assistant turn: tool calls can split a single reply
    // into several text segments, but only the final segment gets the button.
    final copyOwners = _copyOwners;

    // Follow the measured composer height (includes attachment previews, queued
    // messages, multi-line text, safe-area inset). Fall back to 160 before the
    // first measurement so the list never starts fully under the composer.
    final composerH = _ComposerHeight.of(context);
    // 24 = visual gap between last bubble and the jump button.
    final bottomPad = (composerH > 0 ? composerH + 24 : 168)
        .clamp(120, 420)
        .toDouble();
    // The jump button is centred 16 above the top of the composer.
    final jumpBottom = (composerH > 0 ? composerH + 16 : 150)
        .clamp(80, 400)
        .toDouble();

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ListView.separated(
              key: const ValueKey('chat-message-scroll'),
              controller: _controller,
              shrinkWrap: true,
              reverse: true,
              padding: EdgeInsets.fromLTRB(16, 94, 16, bottomPad),
              itemCount: itemCount,
              separatorBuilder: (context, idx) {
                // Tight gap when adjacent to a tool-run card; normal gap
                // otherwise. Display index 0 is the leading streaming or
                // working row, followed by messages newest to oldest.
                bool isTool(int displayIndex) {
                  if (displayIndex < leadingRows) return false;
                  final itemIndex =
                      items.length - 1 - (displayIndex - leadingRows);
                  if (itemIndex < 0 || itemIndex >= items.length) return false;
                  final item = items[itemIndex];
                  return item is ToolRunItem ||
                      item is StartupNote ||
                      item is ToolEvent ||
                      item is ThinkingMsg;
                }

                final tight = isTool(idx) || isTool(idx + 1);
                return SizedBox(height: tight ? 7 : 20);
              },
              itemBuilder: (_, i) {
                // `reverse: true` makes index 0 the newest row. Stable keys
                // keep streaming insertion from rematching unrelated rows.
                var fresh = false;
                if (i >= leadingRows) {
                  final row = items[items.length - 1 - (i - leadingRows)];
                  fresh = widget.live && _shown.add(_rowKey(row));
                }
                Widget constrain(Widget child) => RevealGate(
                  animate: fresh,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: child,
                    ),
                  ),
                );
                if (showWorkingIndicator && i == 0) {
                  return constrain(
                    const KeyedSubtree(
                      key: ValueKey('agent-working'),
                      child: AgentWorkingIndicator(),
                    ),
                  );
                }
                final itemIdx = items.length - 1 - (i - leadingRows);
                final item = items[itemIdx];
                if (item is ToolRunItem) {
                  return constrain(
                    BayaReveal(
                      offset: 5,
                      child: KeyedSubtree(
                        key: ValueKey('tool-run-${item.tools.first.id}'),
                        child: ToolRunGroup(tools: item.tools),
                      ),
                    ),
                  );
                }
                if (item is StartupNote) {
                  return constrain(
                    KeyedSubtree(
                      key: ValueKey('startup-${item.message.id}'),
                      child: StartupNoteRow(text: item.message.text),
                    ),
                  );
                }
                if (item is ToolEvent) {
                  return constrain(
                    BayaReveal(
                      offset: 5,
                      child: KeyedSubtree(
                        key: ValueKey('tool-run-${item.toolCallId}'),
                        child: ToolRunGroup(tools: [item]),
                      ),
                    ),
                  );
                }
                final msg = item as ChatMessage;
                return constrain(
                  KeyedSubtree(
                    key: ValueKey(msg.id),
                    child: switch (msg) {
                      UserMsg() => _once(msg, false, () => UserBubble(msg)),
                      AssistantMsg() => _once(
                        msg,
                        copyOwners.contains(msg),
                        () => AssistantBubble(
                          msg,
                          showCopy: copyOwners.contains(msg),
                        ),
                      ),
                      ThinkingMsg() => ThinkingBlock(
                        id: msg.id,
                        text: msg.text,
                        complete: msg.complete,
                      ),
                      ToolEvent() => ToolRow(tool: msg),
                      CompactionMsg() => CompactionBubble(msg),
                      NoticeMsg() => NoticeBubble(msg),
                      PlanMsg() => PlanCard(msg),
                      AgentImageMsg() => Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: ImageBubble(image: msg.image, caption: ''),
                        ),
                      ),
                    },
                  ),
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: jumpBottom,
            child: Center(
              child: IgnorePointer(
                ignoring: !_showLatest,
                child: AnimatedOpacity(
                  opacity: _showLatest ? 1 : 0,
                  duration: BayaMotion.standard,
                  curve: BayaMotion.enter,
                  child: AnimatedScale(
                    scale: _showLatest ? 1 : .84,
                    duration: BayaMotion.standard,
                    curve: BayaMotion.spring,
                    child: Material(
                      color: Colors.black.withValues(alpha: .76),
                      shape: const CircleBorder(),
                      elevation: 8,
                      shadowColor: Colors.black.withValues(alpha: .28),
                      clipBehavior: Clip.antiAlias,
                      child: SizedBox.square(
                        dimension: 42,
                        child: IconButton(
                          key: const Key('jump-to-latest'),
                          tooltip: context.l10n.jumpToLatest,
                          onPressed: _jumpToLatest,
                          icon: const Icon(
                            LucideIcons.arrowDown,
                            size: 19,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }
}
