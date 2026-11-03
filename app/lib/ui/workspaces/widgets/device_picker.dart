import 'package:app/l10n/l10n.dart';

import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/workspaces/widgets/workspace_scope_field.dart';
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
    final statusLabel = selected.online
        ? context.l10n.statusReady
        : context.l10n.statusOffline;
    return WorkspaceScopeField(
      interactionKey: const ValueKey('new-session-device-picker'),
      label: context.l10n.device,
      value: selected.label,
      supporting: Row(
        key: const ValueKey('new-session-device-status'),
        mainAxisSize: MainAxisSize.min,
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
            statusLabel,
            style: context.typo.sansBody.copyWith(
              fontSize: 11.5,
              height: 1.15,
              color: statusColor,
            ),
          ),
        ],
      ),
      supportingSemantics: statusLabel,
      leading: Icon(
        LucideIcons.monitor,
        size: 19,
        color: active ? colors.accent : colors.muted,
      ),
      enabled: active,
      onTap: () async {
        final choice = await showBayaSheet<String>(
          context,
          sheetKey: const ValueKey('new-session-device-sheet'),
          title: context.l10n.chooseDeviceTitle,
          subtitle: devices.length == 1
              ? context.l10n.onePairedDevice
              : context.l10n.pairedDevicesCount(devices.length),
          builder: (_) =>
              _DevicePickerSheet(devices: devices, selected: selected),
        );
        if (!context.mounted || choice == null) return;
        onChanged(choice);
      },
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A search only once the list is long enough to need one.
        if (widget.devices.length > 6) ...[
          TextField(
            key: const ValueKey('new-session-device-search'),
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: context.l10n.searchDevices,
              prefixIcon: const Icon(LucideIcons.search, size: 18),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (devices.isEmpty)
          Text(
            context.l10n.noMatchingDevices,
            style: context.typo.sansBody.copyWith(color: colors.muted),
          )
        else
          BayaGroup(
            children: [
              for (final device in devices)
                BayaRow(
                  key: ValueKey('new-session-host-${device.id}'),
                  icon: LucideIcons.monitor,
                  label: device.label,
                  subtitle: device.online
                      ? context.l10n.statusReady
                      : context.l10n.statusOffline,
                  selected: device.id == widget.selected.id,
                  onTap: device.online
                      ? () => Navigator.of(context).pop(device.id)
                      : null,
                ),
            ],
          ),
      ],
    );
  }
}
