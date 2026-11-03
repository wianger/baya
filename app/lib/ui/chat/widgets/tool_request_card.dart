import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/tool_activity_details.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// One tool call in the chat. Informational: permission questions are
/// answered in the permission card above the composer, and a call waiting on
/// one is marked here.
class ToolRequestCard extends StatefulWidget {
  final ToolEvent tool;
  final bool initiallyExpanded;

  const ToolRequestCard({
    super.key,
    required this.tool,
    this.initiallyExpanded = false,
  });

  @override
  State<ToolRequestCard> createState() => _ToolRequestCardState();
}

class _ToolRequestCardState extends State<ToolRequestCard> {
  /// Standalone transcript cards start collapsed. The chat flow passes
  /// `initiallyExpanded` for a lone call so its content is visible immediately;
  /// real approvals always start open as well.
  late bool _expanded = widget.initiallyExpanded;
  bool _outputExpanded = false;
  ToolEvent get tool => widget.tool;

  bool get _needsApproval => tool.awaitingApproval;

  /// Errors and real approvals retain emphasis; ordinary activity is quiet.
  Color _statusColor(BuildContext context) {
    final colors = context.colors;
    return switch (tool.status) {
      ToolEventStatus.pending ||
      ToolEventStatus.running => _needsApproval ? colors.accent : colors.muted2,
      ToolEventStatus.completed => colors.muted2,
      ToolEventStatus.failed => colors.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = _statusColor(context);
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
    // The permission card above the composer asks; this card only marks it.
    final expanded = _expanded;
    final preview = content.preview;
    return BayaSurface(
      role: BayaSurfaceRole.content,
      radius: 18,
      elevated: false,
      emphasized: _needsApproval,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              key: ValueKey('tool-details-${tool.toolCallId}'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !_expanded),
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
                          _outputExpanded
                              ? context.l10n.showLess
                              : context.l10n.showFullOutput,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
        ],
      ),
    );
  }

  IconData get _headerIcon {
    final content = ToolContent(tool);
    if (content.isCommand) return LucideIcons.terminal;
    if (content.isFileChange) return LucideIcons.filePen;
    if (content.isRead) return LucideIcons.fileText;
    if (content.isSearch) return LucideIcons.search;
    if (content.isAgentMessage) return LucideIcons.send;
    return LucideIcons.wrench;
  }

  bool get _running =>
      tool.status == ToolEventStatus.pending ||
      tool.status == ToolEventStatus.running;

  /// Compact right-edge state: spinner while running, a label for terminal
  /// states, and a check once an ordinary call finishes.
  Widget _buildStatus(BuildContext context, Color color) {
    final statusLabel = ToolContent(tool).statusLabel;
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
}
