import 'dart:math' as math;

import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/workspaces/widgets/workspace_scope_field.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class AgentPickerField extends StatelessWidget {
  const AgentPickerField({
    super.key,
    required this.agents,
    required this.selected,
    required this.computerLabel,
    required this.enabled,
    required this.onChanged,
  });
  final List<WorkspaceAgent> agents;
  final WorkspaceAgent? selected;
  final String computerLabel;
  final bool enabled;
  final ValueChanged<WorkspaceAgent> onChanged;

  @override
  Widget build(BuildContext context) {
    final active = enabled && agents.isNotEmpty;
    return WorkspaceScopeField(
      interactionKey: const ValueKey('workspace-agent-picker'),
      label: 'Agent',
      value: selected?.label ?? 'Choose an agent',
      leading: Icon(
        LucideIcons.terminal,
        size: 20,
        color: context.colors.muted2,
      ),
      enabled: active,
      onTap: () async {
        final choice = await showModalBottomSheet<WorkspaceAgent>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: Colors.transparent,
          builder: (_) => BayaGlassSurface(
            role: BayaGlassRole.overlay,
            radius: 34,
            elevated: false,
            child: _AgentPickerSheet(
              agents: agents,
              selected: selected,
              computerLabel: computerLabel,
            ),
          ),
        );
        if (!context.mounted || choice == null) return;
        onChanged(choice);
      },
    );
  }
}

class _AgentPickerSheet extends StatefulWidget {
  const _AgentPickerSheet({
    required this.agents,
    required this.selected,
    required this.computerLabel,
  });
  final List<WorkspaceAgent> agents;
  final WorkspaceAgent? selected;
  final String computerLabel;
  @override
  State<_AgentPickerSheet> createState() => _AgentPickerSheetState();
}

class _AgentPickerSheetState extends State<_AgentPickerSheet> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final query = _query.trim().toLowerCase();
    final agents = widget.agents
        .where(
          (agent) => '${agent.label} ${agent.id} ${agent.description}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    final media = MediaQuery.of(context);
    final height = math.min(
      560.0,
      math.max(
        180.0,
        (media.size.height - media.viewInsets.bottom - media.padding.top) * .8,
      ),
    );
    return Padding(
      key: const ValueKey('agent-picker-sheet'),
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Choose Agent', style: context.typo.title),
                        const SizedBox(height: 4),
                        Text(
                          'On ${widget.computerLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.sansBody.copyWith(
                            fontSize: 12,
                            color: colors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close agent picker',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons.x, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: TextField(
                key: const ValueKey('agent-picker-search'),
                decoration: const InputDecoration(
                  hintText: 'Search agents',
                  prefixIcon: Icon(LucideIcons.search, size: 18),
                  isDense: true,
                ),
                onChanged: (query) => setState(() => _query = query),
              ),
            ),
            Flexible(
              fit: FlexFit.loose,
              child: agents.isEmpty
                  ? SizedBox(
                      height: 128,
                      child: Center(
                        child: Text(
                          'No matching agents',
                          style: context.typo.sansBody.copyWith(
                            color: colors.muted,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      itemCount: agents.length,
                      itemBuilder: (context, index) {
                        final agent = agents[index];
                        final selected = widget.selected?.id == agent.id;
                        final subtitle = agent.available
                            ? agent.description
                            : agent.unavailableReason ??
                                  'Not available on this computer';
                        return ListTile(
                          key: ValueKey('agent-option-${agent.id}'),
                          enabled: agent.available,
                          selected: selected,
                          selectedTileColor: colors.userBubble,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: Icon(
                            LucideIcons.terminal,
                            size: 20,
                            color: agent.available
                                ? colors.muted2
                                : colors.muted,
                          ),
                          title: Text(
                            agent.label,
                            style: context.typo.sansBody.copyWith(
                              color: agent.available
                                  ? colors.text
                                  : colors.muted,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          subtitle: subtitle.isEmpty
                              ? null
                              : Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.typo.sansBody.copyWith(
                                    fontSize: 12,
                                    color: colors.muted,
                                  ),
                                ),
                          trailing: selected
                              ? Icon(
                                  LucideIcons.check,
                                  size: 18,
                                  color: colors.accent,
                                )
                              : !agent.available
                              ? Text(
                                  'Unavailable',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: colors.muted,
                                  ),
                                )
                              : null,
                          onTap: !agent.available
                              ? null
                              : () => Navigator.of(context).pop(agent),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
