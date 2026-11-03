import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
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
    final colors = context.colors;
    return BayaSurface(
      role: BayaSurfaceRole.content,
      radius: 22,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('device-switch'),
          onTap: _canOpen ? () => _pick(context) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.selection,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    LucideIcons.monitor,
                    size: 22,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'DEVICE',
                        style: context.typo.monoSmall.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                          color: colors.muted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        devices[selected] ?? context.l10n.pairADevice,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.chevronDown,
                  size: 16,
                  color: _canOpen ? colors.muted2 : colors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
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
  });

  final Map<String, String> workspaces;
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
    final colors = context.colors;
    final detail = workspaces[selected];
    final title = detail == null
        ? hasDevice
              ? context.l10n.noWorkspacesYet
              : context.l10n.chooseDeviceFirst
        : labels[selected] ?? _name(selected!);
    final canOpen = enabled && hasDevice;
    return BayaSurface(
      role: BayaSurfaceRole.content,
      radius: 22,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('workspace-switch'),
          onTap: canOpen ? () => _pick(context) : null,
          child: Padding(
            // Same geometry as DeviceSwitcher so the two cards line up.
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.selection,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    LucideIcons.layoutDashboard,
                    size: 22,
                    color: canOpen ? colors.accent : colors.muted,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'WORKSPACE',
                        style: context.typo.monoSmall.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1,
                          color: colors.muted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.chevronDown,
                  size: 16,
                  color: canOpen ? colors.muted2 : colors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
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
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.createWorkspaceHint,
            style: context.typo.sansBody.copyWith(
              color: colors.muted,
              fontSize: 13,
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
  return showModalBottomSheet<({_ScopeAction action, String? key})>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .7,
    ),
    builder: (sheetContext) {
      final colors = sheetContext.colors;
      void close(_ScopeAction action, [String? key]) =>
          Navigator.of(sheetContext).pop((action: action, key: key));
      return BayaSurface(
        key: sheetKey,
        role: BayaSurfaceRole.overlay,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        elevated: false,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: sheetContext.typo.title.copyWith(
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Tooltip(
                      message: addLabel,
                      child: OutlinedButton.icon(
                        key: Key('$prefix-add'),
                        onPressed: canAdd
                            ? () => close(_ScopeAction.add)
                            : null,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 38),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(LucideIcons.plus, size: 16),
                        label: Text(sheetContext.l10n.newItem),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty && empty != null)
                  empty
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final row in rows)
                          _ScopeTile(
                            key: ValueKey('$prefix-choice-${row.key}'),
                            prefix: prefix,
                            row: row,
                            icon: icon,
                            selected: row.key == selected,
                            onPick: () => close(_ScopeAction.pick, row.key),
                            onRename: () => close(_ScopeAction.rename, row.key),
                            onDelete: () => close(_ScopeAction.delete, row.key),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ScopeTile extends StatelessWidget {
  const _ScopeTile({
    super.key,
    required this.prefix,
    required this.row,
    required this.icon,
    required this.selected,
    required this.onPick,
    required this.onRename,
    required this.onDelete,
  });

  final String prefix;
  final _ScopeRow row;
  final IconData icon;
  final bool selected;
  final VoidCallback onPick;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? colors.inputFill : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? colors.border : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPick,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected ? colors.accent : colors.muted2,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 15,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      if (row.subtitle != null)
                        Text(
                          row.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.sansBody.copyWith(
                            color: colors.muted,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                if (row.rename)
                  IconButton(
                    key: ValueKey('$prefix-rename-${row.key}'),
                    tooltip: context.l10n.rename,
                    onPressed: onRename,
                    icon: Icon(
                      LucideIcons.pencil,
                      size: 16,
                      color: colors.muted2,
                    ),
                  ),
                if (row.delete)
                  IconButton(
                    key: ValueKey('$prefix-delete-${row.key}'),
                    tooltip: context.l10n.delete,
                    onPressed: onDelete,
                    icon: Icon(
                      LucideIcons.trash2,
                      size: 16,
                      color: colors.muted2,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
