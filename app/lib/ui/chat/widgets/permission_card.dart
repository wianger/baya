import 'dart:async';

import 'package:app/acp/acp.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/tool_activity_details.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The agent is waiting for permission (`session/request_permission`).
/// Sits above the composer until any paired phone answers.
class PermissionCard extends StatefulWidget {
  const PermissionCard({
    super.key,
    required this.request,
    required this.tool,
    required this.onAnswer,
  });

  final PermissionRequest request;

  /// The call as the transcript knows it, for its details.
  final ToolEvent? tool;

  /// The chosen option id, or null to cancel.
  final void Function(String? optionId) onAnswer;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  bool _details = false;
  bool _answered = false;

  ToolEvent get _tool =>
      (widget.tool ??
              ToolEvent(
                id: 'permission-${widget.request.toolCall.id}',
                toolCallId: widget.request.toolCall.id,
              ))
          .apply(widget.request.toolCall);

  void _answer(String? optionId) {
    if (_answered) return;
    setState(() => _answered = true);
    unawaited(HapticFeedback.selectionClick());
    widget.onAnswer(optionId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final content = ToolContent(_tool);
    final options = widget.request.options;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: BayaSurface(
            key: const Key('permission-card'),
            role: BayaSurfaceRole.overlay,
            radius: 22,
            emphasized: true,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        LucideIcons.shieldQuestion,
                        size: 17,
                        color: colors.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.agentWaitingApproval,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 12,
                              color: colors.muted,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            content.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.text,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('permission-details'),
                      tooltip: context.l10n.details,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _details = !_details),
                      icon: Icon(
                        _details
                            ? LucideIcons.chevronDown
                            : LucideIcons.chevronRight,
                        size: 17,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ),
                if (_details) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: SingleChildScrollView(
                      child: ToolActivityDetails(tool: _tool),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final option in options.where((o) => !o.allows))
                      OutlinedButton(
                        key: ValueKey('permission-${option.id}'),
                        onPressed: _answered ? null : () => _answer(option.id),
                        child: Text(option.name),
                      ),
                    for (final option in options.where((o) => o.allows))
                      option.kind == PermissionKind.allowOnce
                          ? BayaButton(
                              key: ValueKey('permission-${option.id}'),
                              onPressed: _answered
                                  ? null
                                  : () => _answer(option.id),
                              label: Text(option.name),
                            )
                          : OutlinedButton(
                              key: ValueKey('permission-${option.id}'),
                              onPressed: _answered
                                  ? null
                                  : () => _answer(option.id),
                              child: Text(option.name),
                            ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
