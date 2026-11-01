import 'dart:math' as math;

import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A compact New session device selector. The collapsed field keeps the form
/// stable as more devices are paired; the searchable sheet owns the list.
class DevicePickerField extends StatelessWidget {
  const DevicePickerField({
    super.key,
    required this.devices,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final List<WorkspaceHost> devices;
  final WorkspaceHost selected;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = enabled && devices.isNotEmpty;
    final statusColor = selected.online ? colors.success : colors.muted;
    return BayaGlassSurface(
      role: BayaGlassRole.card,
      radius: 16,
      elevated: false,
      child: InkWell(
        key: const ValueKey('new-session-device-picker'),
        borderRadius: BorderRadius.circular(16),
        onTap: !active
            ? null
            : () async {
                final choice = await showModalBottomSheet<String>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => BayaGlassSurface(
                    role: BayaGlassRole.overlay,
                    radius: 34,
                    elevated: false,
                    child: _DevicePickerSheet(
                      devices: devices,
                      selected: selected,
                    ),
                  ),
                );
                if (!context.mounted || choice == null) return;
                onChanged(choice);
              },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: 'Device',
            enabled: active,
            filled: false,
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.selection,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  LucideIcons.monitor,
                  size: 19,
                  color: active ? colors.accent : colors.muted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.sansBody.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: active ? colors.text : colors.muted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          selected.online ? 'Ready' : 'Offline',
                          style: context.typo.sansBody.copyWith(
                            fontSize: 12,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronDown,
                size: 18,
                color: active ? colors.muted2 : colors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DevicePickerSheet extends StatefulWidget {
  const _DevicePickerSheet({required this.devices, required this.selected});

  final List<WorkspaceHost> devices;
  final WorkspaceHost selected;

  @override
  State<_DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends State<_DevicePickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final query = _query.trim().toLowerCase();
    final devices = widget.devices
        .where(
          (device) =>
              '${device.label} ${device.id}'.toLowerCase().contains(query),
        )
        .toList();
    final media = MediaQuery.of(context);
    final height = math.min(
      560.0,
      math.max(
        210.0,
        (media.size.height - media.viewInsets.bottom - media.padding.top) * .8,
      ),
    );
    return Padding(
      key: const ValueKey('new-session-device-sheet'),
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
                        Text('Choose Device', style: context.typo.title),
                        const SizedBox(height: 4),
                        Text(
                          widget.devices.length == 1
                              ? '1 paired device'
                              : '${widget.devices.length} paired devices',
                          style: context.typo.sansBody.copyWith(
                            fontSize: 12,
                            color: colors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close device picker',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons.x, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: TextField(
                key: const ValueKey('new-session-device-search'),
                decoration: const InputDecoration(
                  hintText: 'Search devices',
                  prefixIcon: Icon(LucideIcons.search, size: 18),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Flexible(
              fit: FlexFit.loose,
              child: devices.isEmpty
                  ? SizedBox(
                      height: 128,
                      child: Center(
                        child: Text(
                          'No matching devices',
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
                      itemCount: devices.length,
                      itemBuilder: (context, index) {
                        final device = devices[index];
                        final selected = widget.selected.id == device.id;
                        final statusColor = device.online
                            ? colors.success
                            : colors.muted;
                        return Opacity(
                          opacity: device.online ? 1 : .52,
                          child: ListTile(
                            key: ValueKey('new-session-host-${device.id}'),
                            enabled: device.online,
                            selected: selected,
                            selectedTileColor: colors.selection,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            leading: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: colors.selection,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(
                                LucideIcons.monitor,
                                size: 19,
                                color: selected ? colors.accent : colors.muted2,
                              ),
                            ),
                            title: Text(
                              device.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.typo.sansBody.copyWith(
                                fontSize: 15,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                            subtitle: Row(
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: statusColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  device.online ? 'Ready' : 'Offline',
                                  style: context.typo.sansBody.copyWith(
                                    fontSize: 12,
                                    color: statusColor,
                                  ),
                                ),
                              ],
                            ),
                            trailing: selected
                                ? Icon(
                                    LucideIcons.check,
                                    size: 18,
                                    color: colors.accent,
                                  )
                                : null,
                            onTap: !device.online
                                ? null
                                : () => Navigator.of(context).pop(device.id),
                          ),
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
