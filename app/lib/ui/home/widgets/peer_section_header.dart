import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Per-pairing section header on the Home list (one per Pi). Shows the device
/// label (nickname → sessionName → epk prefix). The old `via <harness>`
/// subtitle was dropped as redundant.
class PeerSectionHeader extends StatelessWidget {
  final PeerRecord peer;
  const PeerSectionHeader({super.key, required this.peer});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = (peer.nickname?.isNotEmpty ?? false)
        ? peer.nickname!
        : peer.sessionName.isNotEmpty
        ? peer.sessionName
        : peer.remoteEpk.substring(0, 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: [
          Icon(LucideIcons.monitor, size: 13, color: colors.muted),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: kSansFamily,
                fontSize: 11.5,
                color: colors.muted,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
