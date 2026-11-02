import 'package:app/domain/value_objects/workspace.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
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
    final choice = await showModalBottomSheet<({bool add, String? device})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .7,
      ),
      builder: (sheetContext) => BayaGlassSurface(
        role: BayaGlassRole.overlay,
        radius: 34,
        elevated: false,
        child: SafeArea(
          child: Padding(
            key: const Key('device-switcher-sheet'),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                  child: _SwitcherSheetHeader(
                    title: context.l10n.switchDevice,
                    onAdd: enabled && onAdd != null
                        ? () => Navigator.pop(sheetContext, (
                            add: true,
                            device: null,
                          ))
                        : null,
                    addTooltip: context.l10n.pairAnotherComputer,
                    addKey: const Key('device-add'),
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final entry in devices.entries)
                        Dismissible(
                          key: ValueKey('device-row-${entry.key}'),
                          direction: enabled && onDelete != null
                              ? DismissDirection.endToStart
                              : DismissDirection.none,
                          confirmDismiss: (_) => onDelete!(entry.key),
                          onDismissed: (_) {
                            if (sheetContext.mounted) {
                              Navigator.pop(sheetContext);
                            }
                          },
                          background: const _SwipeDeleteBackground(),
                          child: ListTile(
                            selected: entry.key == selected,
                            selectedTileColor: sheetContext.colors.selection,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            leading: Icon(
                              LucideIcons.monitor,
                              color: sheetContext.colors.muted2,
                            ),
                            title: Text(entry.value),
                            trailing: onRename == null
                                ? null
                                : IconButton(
                                    key: ValueKey('device-rename-${entry.key}'),
                                    tooltip: context.l10n.renameDevice,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: enabled
                                        ? () async {
                                            final renamed = await onRename!(
                                              entry.key,
                                            );
                                            if (renamed &&
                                                sheetContext.mounted) {
                                              Navigator.pop(sheetContext);
                                            }
                                          }
                                        : null,
                                    icon: Icon(
                                      LucideIcons.pencil,
                                      size: 17,
                                      color: sheetContext.colors.muted2,
                                    ),
                                  ),
                            onTap: () => Navigator.pop(sheetContext, (
                              add: false,
                              device: entry.key,
                            )),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice.add) {
      onAdd?.call();
      return;
    }
    if (choice.device case final device?) onSelected(device);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaGlassSurface(
      role: BayaGlassRole.content,
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
    final choice =
        await showModalBottomSheet<
          ({bool add, String? workspace, String? rename})
        >(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .72,
          ),
          builder: (sheetContext) {
            final colors = sheetContext.colors;
            return BayaGlassSurface(
              role: BayaGlassRole.overlay,
              radius: 34,
              elevated: false,
              child: SafeArea(
                child: Padding(
                  key: const Key('workspace-switcher-sheet'),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
                        child: _SwitcherSheetHeader(
                          title: context.l10n.switchWorkspace,
                          onAdd: enabled && onCreate != null
                              ? () => Navigator.of(sheetContext).pop((
                                  add: true,
                                  workspace: null,
                                  rename: null,
                                ))
                              : null,
                          addTooltip: context.l10n.newWorkspace,
                          addKey: const Key('workspace-add'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Flexible(
                        child: workspaces.isEmpty
                            ? _EmptyWorkspaceList(
                                onCreate: enabled && onCreate != null
                                    ? () => Navigator.of(sheetContext).pop((
                                        add: true,
                                        workspace: null,
                                        rename: null,
                                      ))
                                    : null,
                              )
                            : BayaGlassSurface(
                                role: BayaGlassRole.content,
                                radius: 26,
                                elevated: false,
                                child: Material(
                                  color: Colors.transparent,
                                  borderRadius: BorderRadius.circular(26),
                                  clipBehavior: Clip.antiAlias,
                                  child: ListView.separated(
                                    shrinkWrap: true,
                                    itemCount: workspaces.length,
                                    separatorBuilder: (_, _) => Divider(
                                      height: 1,
                                      indent: 58,
                                      color: colors.border.withValues(
                                        alpha: .7,
                                      ),
                                    ),
                                    itemBuilder: (_, index) {
                                      final entry = workspaces.entries
                                          .elementAt(index);
                                      final isSelected = entry.key == selected;
                                      final label =
                                          labels[entry.key] ?? _name(entry.key);
                                      final deletable =
                                          enabled &&
                                          onDelete != null &&
                                          (canDelete?.call(entry.key) ?? true);
                                      return Dismissible(
                                        key: ValueKey(
                                          'workspace-row-${entry.key}',
                                        ),
                                        direction: deletable
                                            ? DismissDirection.endToStart
                                            : DismissDirection.none,
                                        confirmDismiss: (_) =>
                                            onDelete!(entry.key),
                                        onDismissed: (_) {
                                          if (sheetContext.mounted) {
                                            Navigator.of(sheetContext).pop();
                                          }
                                        },
                                        background:
                                            const _SwipeDeleteBackground(),
                                        child: ListTile(
                                          key: ValueKey(
                                            'workspace-choice-${entry.key}',
                                          ),
                                          selected: isSelected,
                                          selectedTileColor: colors.selection,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 16,
                                                vertical: 7,
                                              ),
                                          leading: Icon(
                                            LucideIcons.layoutDashboard,
                                            size: 20,
                                            color: isSelected
                                                ? colors.accent
                                                : colors.muted2,
                                          ),
                                          title: Text(
                                            label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: sheetContext.typo.sansBody
                                                .copyWith(
                                                  fontSize: 16,
                                                  fontWeight: isSelected
                                                      ? FontWeight.w600
                                                      : FontWeight.w500,
                                                ),
                                          ),
                                          subtitle: Text(
                                            entry.value,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: sheetContext.typo.sansBody
                                                .copyWith(
                                                  color: colors.muted,
                                                  fontSize: 12,
                                                ),
                                          ),
                                          trailing: enabled && onRename != null
                                              ? IconButton(
                                                  key: ValueKey(
                                                    'workspace-rename-${entry.key}',
                                                  ),
                                                  tooltip: context
                                                      .l10n
                                                      .renameWorkspace,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  onPressed: () =>
                                                      Navigator.of(sheetContext)
                                                          .pop((
                                                            add: false,
                                                            workspace: null,
                                                            rename: entry.key,
                                                          )),
                                                  icon: Icon(
                                                    LucideIcons.pencil,
                                                    size: 17,
                                                    color: colors.muted2,
                                                  ),
                                                )
                                              : null,
                                          onTap: () =>
                                              Navigator.of(sheetContext).pop((
                                                add: false,
                                                workspace: entry.key,
                                                rename: null,
                                              )),
                                        ),
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
            );
          },
        );
    if (!context.mounted || choice == null) return;
    if (choice.add) {
      onCreate?.call();
      return;
    }
    if (choice.rename case final key?) {
      final label = labels[key] ?? _name(key);
      await onRename?.call(key, label);
      return;
    }
    if (choice.workspace case final workspace?) onSelected(workspace);
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
    return BayaGlassSurface(
      role: BayaGlassRole.content,
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
  const _EmptyWorkspaceList({this.onCreate});

  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaGlassSurface(
      role: BayaGlassRole.content,
      radius: 26,
      elevated: false,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(26),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          key: const Key('workspace-empty-create'),
          onTap: onCreate,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 7,
          ),
          leading: Icon(
            LucideIcons.layoutDashboard,
            size: 20,
            color: colors.muted2,
          ),
          title: Text(
            context.l10n.noWorkspacesYet,
            style: context.typo.sansBody.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            context.l10n.createWorkspaceHint,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.typo.sansBody.copyWith(
              color: colors.muted,
              fontSize: 12,
            ),
          ),
          trailing: Icon(
            LucideIcons.chevronRight,
            size: 18,
            color: onCreate == null ? colors.muted : colors.muted2,
          ),
        ),
      ),
    );
  }
}

class _SwitcherSheetHeader extends StatelessWidget {
  const _SwitcherSheetHeader({
    required this.title,
    required this.onAdd,
    required this.addTooltip,
    required this.addKey,
  });

  final String title;
  final VoidCallback? onAdd;
  final String addTooltip;
  final Key addKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              title,
              style: context.typo.title.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          BayaGlassSurface(
            role: BayaGlassRole.control,
            radius: 22,
            elevated: false,
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                key: addKey,
                tooltip: addTooltip,
                onPressed: onAdd,
                icon: Icon(
                  LucideIcons.plus,
                  size: 19,
                  color: onAdd == null
                      ? colors.muted.withValues(alpha: .35)
                      : colors.accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwipeDeleteBackground extends StatelessWidget {
  const _SwipeDeleteBackground();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 22),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.trash2, size: 18, color: colors.error),
          const SizedBox(width: 7),
          Text(
            context.l10n.delete,
            style: context.typo.sansBody.copyWith(
              color: colors.error,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
