/// Rows in the drawer and search, as Claude lists them: an outline icon and
/// a name in one line, no card around them.
library;

import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// A place the drawer leads to, or a session: its icon and name.
class DrawerLine extends StatelessWidget {
  const DrawerLine({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.highlighted = false,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool highlighted;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: highlighted ? colors.inputFill : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 54),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 22, color: colors.text),
                const SizedBox(width: 18),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 17,
                      height: 24 / 17,
                      color: colors.text,
                      fontWeight: highlighted
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One session: a spinner while it works, a dot when it has news.
class SessionListRow extends StatelessWidget {
  const SessionListRow({
    super.key,
    required this.vm,
    required this.item,
    required this.onOpen,
    this.onMore,
    this.highlighted = false,
  });

  final HomeViewModel vm;
  final HomeItem item;
  final bool highlighted;
  final VoidCallback onOpen;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final working = vm.isRoomWorking(item.peer.remoteEpk, item.sessionId);
    final unread =
        !working &&
        (context.watch<Preferences?>()?.isUnread(
              item.peer.remoteEpk,
              item.session,
            ) ??
            false);
    final more = onMore;
    return DrawerLine(
      icon: LucideIcons.messageCircle,
      label: vm.displayNameOf(item),
      highlighted: highlighted,
      onTap: onOpen,
      onLongPress: more == null
          ? null
          : () {
              unawaited(HapticFeedback.mediumImpact());
              more();
            },
      trailing: working
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.4,
                  color: colors.muted,
                ),
              ),
            )
          : unread
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Container(
                key: const Key('session-unread'),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: colors.text,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );
  }
}
