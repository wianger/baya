import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/tool_activity_details.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:app/ui/chat/widgets/thinking_block.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// Inline tool execution card that appears in the chat flow.
//
// Historically this widget rendered Allow/Deny buttons + a 60s countdown
// assuming the Pi paused execution until the user decided. With the current
// Claude SDK integration the pi-extension emits `tool_request` AFTER the
// SDK has already accepted the tool (`tool_execution_start` fires post
// auto-approval), so the buttons could only blink for a few hundred
// milliseconds before `tool_result` arrived — confusing UX with no real
// gating. Pi cards stay informational. Codex explicitly marks requests
// that are paused for a real decision with `approval_required`.

class ToolRequestCard extends StatefulWidget {
  final ToolEvent tool;
  final void Function(String toolCallId, ApproveDecision decision)? onDecide;

  const ToolRequestCard({super.key, required this.tool, this.onDecide});

  @override
  State<ToolRequestCard> createState() => _ToolRequestCardState();
}

class _ToolRequestCardState extends State<ToolRequestCard> {
  /// Cards start collapsed to a single readable row; tapping one reveals the
  /// command, output and outcome. Real approvals always start open.
  bool _expanded = false;
  bool _outputExpanded = false;
  ToolEvent get tool => widget.tool;
  void Function(String, ApproveDecision)? get onDecide => widget.onDecide;

  bool get _needsApproval =>
      tool.status == ToolEventStatus.pending &&
      tool.args is Map &&
      tool.args['approval_required'] == true;

  /// Errors and real approvals retain emphasis; ordinary activity is quiet.
  Color _statusColor(BuildContext context) {
    final colors = context.colors;
    return switch (tool.status) {
      ToolEventStatus.pending ||
      ToolEventStatus.allowed => _needsApproval ? colors.accent : colors.muted2,
      ToolEventStatus.completed => colors.muted2,
      ToolEventStatus.failed => colors.error,
      ToolEventStatus.denied || ToolEventStatus.expired => colors.muted,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = _statusColor(context);
    final name = tool.tool.toLowerCase();
    if (!_needsApproval &&
        (_running || tool.status == ToolEventStatus.completed) &&
        const {'think', 'thinking', 'reasoning'}.contains(name)) {
      final args = tool.args;
      return ThinkingBlock(
        text:
            ToolContent(tool).output.text ??
            (args is Map
                ? _stringArg(args, const ['thought', 'thinking', 'text'])
                : ''),
        complete: !_running,
      );
    }
    final content = ToolContent(tool);
    final outputText = [
      content.output.text,
      content.output.stderr,
    ].whereType<String>().join('\n');
    final hasOutput = outputText.trim().isNotEmpty;
    final longOutput =
        hasOutput &&
        (outputText.length > 900 || '\n'.allMatches(outputText).length > 12);
    // Collapsed by default: the row shows what ran, and the command, output and
    // outcome stay one tap away. Real approvals always start open.
    final expanded = _expanded || _needsApproval;
    final preview = _needsApproval ? null : content.preview;
    return BayaGlassSurface(
      role: BayaGlassRole.control,
      radius: 18,
      elevated: false,
      emphasized: _needsApproval,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: !_needsApproval,
            expanded: expanded,
            child: InkWell(
              key: ValueKey('tool-details-${tool.toolCallId}'),
              borderRadius: BorderRadius.circular(10),
              onTap: _needsApproval
                  ? null
                  : () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(_headerIcon, size: 16, color: color),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            content.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 14,
                              color: color,
                            ),
                          ),
                          if (!expanded && preview != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    (content.usesProseDetails
                                            ? context.typo.sansBody
                                            : context.typo.monoSmall)
                                        .copyWith(
                                          fontSize: 11.5,
                                          color: colors.muted,
                                        ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: _buildStatus(context, color),
                    ),
                    if (!_needsApproval) ...[
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(
                          expanded
                              ? LucideIcons.chevronDown
                              : LucideIcons.chevronRight,
                          size: 15,
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Container(
              margin: const EdgeInsets.only(left: 9, top: 2, bottom: 8),
              padding: const EdgeInsets.only(left: 17),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: colors.border, width: 2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ToolActivityDetails(
                    tool: tool,
                    resultMaxHeight: _outputExpanded ? 340 : 132,
                  ),
                  if (longOutput)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: ValueKey('tool-output-toggle-${tool.toolCallId}'),
                        onPressed: () =>
                            setState(() => _outputExpanded = !_outputExpanded),
                        child: Text(
                          _outputExpanded ? 'Show less' : 'Show full output',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  if (_needsApproval) ...[
                    Text(
                      'The agent is waiting for your approval.',
                      style: TextStyle(color: colors.text, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton(
                          onPressed: onDecide == null
                              ? null
                              : () => onDecide!(
                                  tool.toolCallId,
                                  ApproveDecision.deny,
                                ),
                          child: const Text('Deny'),
                        ),
                        const SizedBox(width: 10),
                        BayaGlassButton(
                          onPressed: onDecide == null
                              ? null
                              : () => onDecide!(
                                  tool.toolCallId,
                                  ApproveDecision.allow,
                                ),
                          label: const Text('Allow once'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  IconData get _headerIcon {
    if (ToolContent(tool).isCommand) return LucideIcons.terminal;
    return switch (tool.tool.toLowerCase()) {
      'read' => LucideIcons.fileText,
      'edit' || 'write' || 'apply_patch' || 'filechange' => LucideIcons.filePen,
      'web_search' || 'websearch' => LucideIcons.search,
      final other when other.contains('message') || other.contains('agent') =>
        LucideIcons.send,
      _ => LucideIcons.wrench,
    };
  }

  bool get _running =>
      tool.status == ToolEventStatus.pending ||
      tool.status == ToolEventStatus.allowed;

  /// Compact right-edge state: spinner while running, a label for terminal
  /// states, and a check once an ordinary call finishes.
  Widget _buildStatus(BuildContext context, Color color) {
    final statusLabel = switch (tool.status) {
      ToolEventStatus.pending ||
      ToolEventStatus.allowed => _needsApproval ? 'Approval' : 'Running',
      ToolEventStatus.completed => 'Done',
      ToolEventStatus.failed => 'Failed',
      ToolEventStatus.denied => 'Denied',
      ToolEventStatus.expired => 'Expired',
    };
    if (_running && !_needsApproval) {
      return SizedBox(
        width: 13,
        height: 13,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
      );
    }
    if (tool.status != ToolEventStatus.completed) {
      return Text(
        statusLabel,
        style: context.typo.sansBody.copyWith(fontSize: 11, color: color),
      );
    }
    return Icon(LucideIcons.check, size: 14, color: context.colors.muted);
  }

  static String _stringArg(Map args, List<String> keys) {
    for (final key in keys) {
      final value = args[key];
      if (value is String) return value;
    }
    return '';
  }
}
