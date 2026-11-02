import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/baya_activity_card.dart';
import 'package:app/ui/chat/widgets/tool_activity_details.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Collapsed summary for a *run* of consecutive tool calls — text, thinking or
/// a new user turn ends the run, so unrelated calls never get merged. Mirrors
/// the Claude mobile pattern: one quiet row that opens a list of the actions,
/// each of which expands into its command and result.
class ToolRunGroup extends StatelessWidget {
  const ToolRunGroup({super.key, required this.tools, this.onDecide});

  final List<ToolEvent> tools;
  final void Function(String toolCallId, ApproveDecision decision)? onDecide;

  bool _isCommand(ToolEvent tool) {
    return ToolContent(tool).isCommand;
  }

  String get _summary {
    if (tools.length == 1) return ToolContent(tools.single).title;
    final commands = tools.where(_isCommand).length;
    final others = tools.length - commands;
    if (commands > 0 && others > 0) {
      return appL10n.ranAndUsed(commands, others);
    }
    if (commands > 0) {
      return appL10n.ranCommands(commands);
    }
    return appL10n.usedTools(others);
  }

  bool get _failed => tools.any((t) => t.status == ToolEventStatus.failed);

  /// One readable line under the summary so the row says what actually ran
  /// instead of only how many calls there were. Uses the first call's own
  /// description/command, and appends the remaining count so a long run stays
  /// honest about being truncated.
  String? get _previewLine {
    if (tools.isEmpty) return null;
    final head = ToolContent(tools.first).preview;
    if (head == null) return null;
    if (tools.length == 1) return head;
    return appL10n.andMore(head, tools.length - 1);
  }

  IconData get _icon {
    if (tools.every(_isCommand)) return LucideIcons.terminal;
    final content = ToolContent(tools.first);
    if (content.isFileChange) return LucideIcons.filePen;
    if (content.isRead) return LucideIcons.fileText;
    if (content.isSearch) return LucideIcons.search;
    if (content.isAgentMessage) return LucideIcons.send;
    return LucideIcons.wrench;
  }

  @override
  Widget build(BuildContext context) {
    if (tools.length == 1) {
      return ToolRequestCard(
        tool: tools.single,
        onDecide: onDecide,
        initiallyExpanded: true,
      );
    }
    final colors = context.colors;
    return BayaActivityCard(
      disclosureKey: const Key('tool-run-group'),
      leading: Icon(
        _failed ? LucideIcons.circleAlert : _icon,
        size: 19,
        color: _failed ? colors.error : colors.muted2,
      ),
      title: _summary,
      titleColor: _failed ? colors.error : colors.muted2,
      preview: _previewLine,
      previewMonospace: !ToolContent(tools.first).usesProseDetails,
      onTap: () => _open(context),
    );
  }

  Future<void> _open(BuildContext context) async {
    if (tools.length == 1) {
      await _showDetail(context, tools.single);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .38),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(34)),
      ),
      builder: (sheetContext) {
        final colors = sheetContext.colors;
        return BayaFloatingActivitySurface(
          surfaceKey: const ValueKey('tool-run-list-sheet'),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * .82,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        SizedBox.square(
                          dimension: 42,
                          child: IconButton.filledTonal(
                            tooltip: context.l10n.close,
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(LucideIcons.x, size: 20),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: Text(
                              _summary,
                              style: sheetContext.typo.title.copyWith(
                                fontSize: 19,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 42),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: BayaSurface(
                        role: BayaSurfaceRole.content,
                        radius: 24,
                        elevated: false,
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(24),
                          clipBehavior: Clip.antiAlias,
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: tools.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              indent: 48,
                              color: colors.border.withValues(alpha: .7),
                            ),
                            itemBuilder: (_, index) {
                              final tool = tools[index];
                              return ListTile(
                                key: ValueKey('tool-run-${tool.id}'),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 5,
                                ),
                                leading: Icon(
                                  _iconFor(tool),
                                  size: 19,
                                  color: colors.muted2,
                                ),
                                title: Text(_labelFor(tool)),
                                subtitle: Text(
                                  ToolContent(tool).preview ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: sheetContext.typo.sansBody.copyWith(
                                    color: colors.muted,
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: Icon(
                                  LucideIcons.chevronRight,
                                  size: 17,
                                  color: colors.muted,
                                ),
                                onTap: () => _showDetail(sheetContext, tool),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _iconFor(ToolEvent tool) {
    if (_isCommand(tool)) return LucideIcons.terminal;
    final content = ToolContent(tool);
    if (content.isFileChange) return LucideIcons.filePen;
    if (content.isRead) return LucideIcons.fileText;
    if (content.isSearch) return LucideIcons.search;
    if (content.isAgentMessage) return LucideIcons.send;
    return LucideIcons.wrench;
  }

  String _labelFor(ToolEvent tool) {
    return ToolContent(tool).title;
  }

  Future<void> _showDetail(BuildContext context, ToolEvent tool) {
    return showBayaActivityDetailSheet(
      context,
      title: ToolContent(tool).toolName,
      child: ToolActivityDetails(tool: tool, showHeader: true),
    );
  }
}
