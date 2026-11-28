import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/workspaces/widgets/workspace_scope_field.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Devices are a top-level destination, presented as a prominent card and
/// sheet. The whole card is tappable so switching never depends on hitting a
/// small trailing icon.
class DeviceSwitcher extends StatelessWidget {
  const DeviceSwitcher({
    super.key,
    required this.devices,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.onAdd,
    this.onRename,
    this.onDelete,
  });

  final Map<String, String> devices;
  final String? selected;
  final ValueChanged<String> onSelected;
  final bool enabled;
  final VoidCallback? onAdd;
  final Future<bool> Function(String epk)? onRename;
  final Future<bool> Function(String epk)? onDelete;

  bool get _canOpen => enabled && (devices.isNotEmpty || onAdd != null);

  Future<void> _pick(BuildContext context) async {
    final choice = await _showScopeSheet(
      context,
      sheetKey: const Key('device-switcher-sheet'),
      prefix: 'device',
      title: context.l10n.switchDevice,
      addLabel: context.l10n.pairAnotherComputer,
      canAdd: enabled && onAdd != null,
      icon: LucideIcons.monitor,
      selected: selected,
      rows: [
        for (final entry in devices.entries)
          (
            key: entry.key,
            label: entry.value,
            subtitle: null,
            rename: enabled && onRename != null,
            delete: enabled && onDelete != null,
            working: false,
          ),
      ],
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case (action: _ScopeAction.add, key: _):
        onAdd?.call();
      case (action: _ScopeAction.pick, :final key?):
        onSelected(key);
      case (action: _ScopeAction.rename, :final key?):
        await onRename?.call(key);
      case (action: _ScopeAction.delete, :final key?):
        await onDelete?.call(key);
      default:
    }
  }

  @override
  Widget build(BuildContext context) {
    return WorkspaceScopeField(
      interactionKey: const Key('device-switch'),
      label: context.l10n.device,
      value: devices[selected] ?? context.l10n.pairADevice,
      leading: Icon(
        LucideIcons.monitor,
        size: 20,
        color: context.colors.accent,
      ),
      enabled: _canOpen,
      onTap: () => _pick(context),
    );
  }
}

/// Workspaces are phone-side logical groups. Sessions inside one group may
/// come from unrelated folders. The card mirrors [DeviceSwitcher]'s geometry so
/// the two read as sibling scopes; the icon, the small-caps label and the
/// subtitle keep them distinguishable.
class WorkspaceSwitcher extends StatelessWidget {
  const WorkspaceSwitcher({
    super.key,
    required this.workspaces,
    this.labels = const {},
    required this.selected,
    required this.hasDevice,
    required this.onSelected,
    this.onCreate,
    this.onRename,
    this.canDelete,
    this.onDelete,
    this.enabled = true,
    this.working = const {},
  });

  final Map<String, String> workspaces;

  /// Workspaces with a session working or waiting for an answer.
  final Set<String> working;
  final Map<String, String> labels;
  final String? selected;
  final bool hasDevice;
  final bool enabled;
  final ValueChanged<String> onSelected;
  final VoidCallback? onCreate;
  final Future<bool> Function(String key, String name)? onRename;
  final bool Function(String key)? canDelete;
  final Future<bool> Function(String key)? onDelete;

  String _name(String key) => workspaceId(key) ?? key;

  Future<void> _pick(BuildContext context) async {
    final choice = await _showScopeSheet(
      context,
      sheetKey: const Key('workspace-switcher-sheet'),
      prefix: 'workspace',
      title: context.l10n.switchWorkspace,
      addLabel: context.l10n.newWorkspace,
      canAdd: enabled && onCreate != null,
      icon: LucideIcons.layoutDashboard,
      selected: selected,
      empty: const _EmptyWorkspaceList(),
      rows: [
        for (final entry in workspaces.entries)
          (
            key: entry.key,
            label: labels[entry.key] ?? _name(entry.key),
            subtitle: entry.value.isEmpty ? null : entry.value,
            rename: enabled && onRename != null,
            delete:
                enabled &&
                onDelete != null &&
                (canDelete?.call(entry.key) ?? true),
            working: working.contains(entry.key),
          ),
      ],
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case (action: _ScopeAction.add, key: _):
        onCreate?.call();
      case (action: _ScopeAction.pick, :final key?):
        onSelected(key);
      case (action: _ScopeAction.rename, :final key?):
        await onRename?.call(key, labels[key] ?? _name(key));
      case (action: _ScopeAction.delete, :final key?):
        await onDelete?.call(key);
      default:
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = workspaces[selected];
    final title = detail == null
        ? hasDevice
              ? context.l10n.noWorkspacesYet
              : context.l10n.chooseDeviceFirst
        : labels[selected] ?? _name(selected!);
    final canOpen = enabled && hasDevice;
    return WorkspaceScopeField(
      interactionKey: const Key('workspace-switch'),
      label: context.l10n.workspace,
      value: title,
      // Another workspace has a session at work: a dot says so.
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            LucideIcons.layoutDashboard,
            size: 20,
            color: canOpen ? context.colors.accent : context.colors.muted,
          ),
          if (working.any((key) => key != selected))
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                key: const Key('workspace-working-elsewhere'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: context.colors.working,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.colors.bg, width: 1.5),
                ),
              ),
            ),
        ],
      ),
      enabled: canOpen,
      onTap: () => _pick(context),
    );
  }
}

class _EmptyWorkspaceList extends StatelessWidget {
  const _EmptyWorkspaceList();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      key: const Key('workspace-empty-create'),
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.noWorkspacesYet,
            style: context.typo.sansBody.copyWith(
              fontSize: BayaType.body,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.createWorkspaceHint,
            style: context.typo.sansBody.copyWith(
              color: colors.muted,
              fontSize: BayaType.footnote,
            ),
          ),
        ],
      ),
    );
  }
}

enum _ScopeAction { pick, add, rename, delete }

typedef _ScopeRow = ({
  String key,
  String label,
  String? subtitle,
  bool rename,
  bool delete,
  bool working,
});

/// The sheet both switchers open: a title with a "New" button, then one row
/// per choice with its own rename and delete buttons.
Future<({_ScopeAction action, String? key})?> _showScopeSheet(
  BuildContext context, {
  required Key sheetKey,
  required String prefix,
  required String title,
  required String addLabel,
  required bool canAdd,
  required IconData icon,
  required String? selected,
  required List<_ScopeRow> rows,
  Widget? empty,
}) {
  return showBayaSheet<({_ScopeAction action, String? key})>(
    context,
    sheetKey: sheetKey,
    title: title,
    // A round plus, as Claude adds things.
    action: Builder(
      builder: (headerContext) => IconButton(
        key: Key('$prefix-add'),
        tooltip: addLabel,
        onPressed: canAdd
            ? () =>
                  Navigator.of(headerContext)
                      .pop((action: _ScopeAction.add, key: null))
            : null,
        style: IconButton.styleFrom(
          backgroundColor: headerContext.colors.selection,
          fixedSize: const Size.square(40),
          shape: const CircleBorder(),
        ),
        icon: Icon(
          LucideIcons.plus,
          size: 20,
          color: headerContext.colors.text,
        ),
      ),
    ),
    builder: (sheetContext) {
      final colors = sheetContext.colors;
      void close(_ScopeAction action, [String? key]) =>
          Navigator.of(sheetContext).pop((action: action, key: key));
      if (rows.isEmpty && empty != null) return empty;
      return BayaGroup(
        children: [
          for (final row in rows)
            BayaRow(
              key: ValueKey('$prefix-choice-${row.key}'),
              icon: icon,
              label: row.label,
              subtitle: row.subtitle,
              selected: row.key == selected,
              onTap: () => close(_ScopeAction.pick, row.key),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A session in it is at work.
                  if (row.working)
                    Padding(
                      key: ValueKey('$prefix-working-${row.key}'),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.4,
                          color: colors.working,
                        ),
                      ),
                    ),
                  if (row.rename)
                    IconButton(
                      key: ValueKey('$prefix-rename-${row.key}'),
                      tooltip: sheetContext.l10n.rename,
                      onPressed: () => close(_ScopeAction.rename, row.key),
                      icon: Icon(
                        LucideIcons.pencil,
                        size: 16,
                        color: colors.muted2,
                      ),
                    ),
                  if (row.delete)
                    IconButton(
                      key: ValueKey('$prefix-delete-${row.key}'),
                      // A workspace closes, as a space in herdr does.
                      tooltip: prefix == 'workspace'
                          ? sheetContext.l10n.closeSessionConfirm
                          : sheetContext.l10n.delete,
                      onPressed: () => close(_ScopeAction.delete, row.key),
                      icon: Icon(
                        prefix == 'workspace'
                            ? LucideIcons.circleX
                            : LucideIcons.trash2,
                        size: 16,
                        color: colors.muted2,
                      ),
                    ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
