import 'package:app/acp/acp.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/shimmer_text.dart';
import 'package:app/ui/chat/widgets/tool_activity_details.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A run of consecutive tool calls (text, thinking or a new turn ends a run).
/// One call is a single row; several fold into one summary line that opens
/// into their rows. Rows open in place into the command, diff or output.
class ToolRunGroup extends StatefulWidget {
  const ToolRunGroup({super.key, required this.tools});

  final List<ToolEvent> tools;

  @override
  State<ToolRunGroup> createState() => _ToolRunGroupState();
}

class _ToolRunGroupState extends State<ToolRunGroup> {
  bool _open = false;

  List<ToolEvent> get tools => widget.tools;

  String get _summary {
    final commands = tools.where((t) => ToolContent(t).isCommand).length;
    final others = tools.length - commands;
    if (commands > 0 && others > 0) return appL10n.ranAndUsed(commands, others);
    if (commands > 0) return appL10n.ranCommands(commands);
    return appL10n.usedTools(others);
  }

  @override
  Widget build(BuildContext context) {
    if (tools.length == 1) return ToolRow(tool: tools.single);
    final colors = context.colors;
    final failed = tools.any((t) => t.status == ToolEventStatus.failed);
    final running = tools.any(
      (t) =>
          t.status == ToolEventStatus.running ||
          t.status == ToolEventStatus.pending,
    );
    final style = context.typo.sansBody.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: failed ? colors.error : colors.muted2,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const Key('tool-run-group'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(
              children: [
                Icon(
                  failed ? LucideIcons.circleAlert : LucideIcons.layers,
                  size: 15,
                  color: failed ? colors.error : colors.muted,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: running
                      ? ShimmerText(_summary, style: style)
                      : Text(_summary, style: style),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: _open ? .25 : 0,
                  duration: BayaMotion.fast,
                  child: Icon(
                    LucideIcons.chevronRight,
                    size: 15,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: BayaMotion.standard,
          curve: BayaMotion.enter,
          alignment: Alignment.topLeft,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Container(
                  margin: const EdgeInsets.only(left: 9),
                  padding: const EdgeInsets.only(left: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: colors.border, width: 1.5),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final tool in tools) ToolRow(tool: tool)],
                  ),
                ),
        ),
      ],
    );
  }
}

/// One tool call: what it did on one line, with its details a tap away. A
/// call waiting on permission is marked; the card above the composer asks.
class ToolRow extends StatefulWidget {
  const ToolRow({super.key, required this.tool});

  final ToolEvent tool;

  @override
  State<ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<ToolRow> {
  bool _open = false;
  bool _full = false;

  ToolEvent get tool => widget.tool;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final content = ToolContent(tool);
    final running =
        tool.status == ToolEventStatus.running ||
        tool.status == ToolEventStatus.pending;
    final approval = tool.awaitingApproval;
    final failed = tool.status == ToolEventStatus.failed;
    final color = failed
        ? colors.error
        : approval
        ? colors.accent
        : colors.muted2;
    final style = context.typo.sansBody.copyWith(
      fontSize: 14,
      color: color,
      fontWeight: FontWeight.w500,
    );
    final output = [
      content.output.text,
      content.output.stderr,
    ].whereType<String>().join('\n');
    final long = output.length > 900 || '\n'.allMatches(output).length > 12;
    final stats = content.diffStats;
    final detail = content.detailLine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            key: ValueKey('tool-details-${tool.toolCallId}'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 15,
                    child: running && !approval
                        ? CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: colors.muted2,
                          )
                        : Icon(
                            failed ? LucideIcons.circleX : _icon(content),
                            size: 15,
                            color: failed || approval ? color : colors.muted,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: running && !approval
                        ? ShimmerText(content.title, style: style)
                        : Text(
                            content.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.monoSmall.copyWith(
                          fontSize: 12,
                          color: colors.muted,
                        ),
                      ),
                    ),
                  ],
                  if (stats != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '+${stats.added}',
                      style: context.typo.monoSmall.copyWith(
                        fontSize: 12,
                        color: colors.success,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '−${stats.removed}',
                      style: context.typo.monoSmall.copyWith(
                        fontSize: 12,
                        color: colors.error,
                      ),
                    ),
                  ],
                  if (approval) ...[
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.approval,
                      style: context.typo.sansBody.copyWith(
                        fontSize: 12,
                        color: colors.accent,
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _open ? .25 : 0,
                    duration: BayaMotion.fast,
                    child: Icon(
                      LucideIcons.chevronRight,
                      size: 15,
                      color: colors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: BayaMotion.standard,
          curve: BayaMotion.enter,
          alignment: Alignment.topLeft,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(25, 2, 0, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ToolActivityDetails(
                        tool: tool,
                        resultMaxHeight: _full ? 420 : 160,
                      ),
                      if (long)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: ValueKey(
                              'tool-output-toggle-${tool.toolCallId}',
                            ),
                            onPressed: () => setState(() => _full = !_full),
                            child: Text(
                              _full
                                  ? context.l10n.showLess
                                  : context.l10n.showFullOutput,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  static IconData _icon(ToolContent content) {
    if (content.isCommand) return LucideIcons.squareTerminal;
    if (content.isFileChange) return LucideIcons.filePen;
    if (content.isRead) return LucideIcons.fileText;
    if (content.isSearch) return LucideIcons.search;
    if (content.tool.kind == ToolKind.fetch) return LucideIcons.globe;
    if (content.usesProseDetails) return LucideIcons.sparkle;
    return LucideIcons.wrench;
  }
}
