import 'package:app/l10n/l10n.dart';

import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
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
      label: context.l10n.agent,
      value: selected?.label ?? context.l10n.chooseAgent,
      leading: Icon(
        LucideIcons.terminal,
        size: 20,
        color: context.colors.muted2,
      ),
      enabled: active,
      onTap: () async {
        final choice = await showBayaSheet<WorkspaceAgent>(
          context,
          sheetKey: const ValueKey('agent-picker-sheet'),
          title: context.l10n.chooseAgent,
          subtitle: context.l10n.onComputer(computerLabel),
          builder: (_) => _AgentPickerSheet(agents: agents, selected: selected),
        );
        if (!context.mounted || choice == null) return;
        onChanged(choice);
      },
    );
  }
}

class _AgentPickerSheet extends StatefulWidget {
  const _AgentPickerSheet({required this.agents, required this.selected});
  final List<WorkspaceAgent> agents;
  final WorkspaceAgent? selected;
  @override
  State<_AgentPickerSheet> createState() => _AgentPickerSheetState();
}

class _AgentPickerSheetState extends State<_AgentPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final agents = widget.agents
        .where(
          (agent) => '${agent.label} ${agent.id}'.toLowerCase().contains(query),
        )
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A search only once the list is long enough to need one.
        if (widget.agents.length > 6) ...[
          TextField(
            key: const ValueKey('agent-picker-search'),
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: context.l10n.searchAgents,
              prefixIcon: const Icon(LucideIcons.search, size: 18),
            ),
          ),
          const SizedBox(height: 12),
        ],
        BayaGroup(
          children: [
            for (final agent in agents)
              BayaRow(
                key: ValueKey('agent-option-${agent.id}'),
                icon: LucideIcons.terminal,
                label: agent.label,
                subtitle: agent.available
                    ? agent.id
                    : context.l10n.notAvailableOnComputer,
                monospaceSubtitle: agent.available,
                selected: agent == widget.selected,
                onTap: agent.available
                    ? () => Navigator.of(context).pop(agent)
                    : null,
              ),
          ],
        ),
      ],
    );
  }
}
