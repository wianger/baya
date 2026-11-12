import 'package:app/data/preferences/preferences.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_group.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_actions.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// One session wherever sessions are listed: title, then agent, folder and
/// how long ago, with a dot when the agent did something not yet seen
/// here (or the computer is away). [highlighted] marks the open one;
/// [onMore] adds the ⋯ that opens the session sheet.
class SessionRow extends StatelessWidget {
  const SessionRow({
    super.key,
    required this.vm,
    required this.item,
    this.onOpen,
    this.onMore,
    this.highlighted = false,
  });

  final HomeViewModel vm;
  final HomeItem item;
  final VoidCallback? onOpen;
  final VoidCallback? onMore;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final working = vm.isRoomWorking(item.peer.remoteEpk, item.sessionId);
    final online = vm.isRoomLive(item.peer.remoteEpk, item.sessionId);
    final unread =
        !working &&
        (context.watch<Preferences?>()?.isUnread(
              item.peer.remoteEpk,
              item.session,
            ) ??
            false);
    final folder = item.session.cwd
        .split(RegExp(r'[/\\]'))
        .lastWhere((part) => part.isNotEmpty, orElse: () => item.session.cwd);
    final when = item.session.updatedAt;
    return BayaRow(
      icon: working ? LucideIcons.loaderCircle : LucideIcons.messageSquare,
      spinning: working,
      label: vm.displayNameOf(item),
      subtitle: [
        item.session.agentName,
        if (folder.isNotEmpty) folder,
        if (when != null) relativeTime(context, when),
      ].join(' · '),
      highlighted: highlighted,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Working spins its icon; the dot says what is new, or that the
          // computer is away.
          if (unread || !online)
            Padding(
              padding: EdgeInsets.only(left: 10, right: onMore == null ? 6 : 0),
              child: Semantics(
                label: unread
                    ? context.l10n.unread
                    : context.l10n.statusOffline,
                child: Container(
                  key: unread ? const Key('session-unread') : null,
                  width: unread ? 8 : 7,
                  height: unread ? 8 : 7,
                  decoration: BoxDecoration(
                    color: unread
                        ? colors.accent
                        : colors.muted.withValues(alpha: .5),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          if (onMore != null)
            IconButton(
              key: ValueKey(
                'session-more-${item.peer.remoteEpk}-${item.sessionId}',
              ),
              tooltip: context.l10n.sessionActions,
              onPressed: onMore,
              icon: Icon(LucideIcons.ellipsis, size: 18, color: colors.muted),
            ),
        ],
      ),
      onTap: onOpen ?? () => openSession(context, item),
    );
  }
}

/// "just now", "5m ago", "3h ago", "2d ago", then the date.
String relativeTime(BuildContext context, DateTime time) {
  final elapsed = DateTime.now().difference(time.toLocal());
  final l10n = context.l10n;
  if (elapsed.inMinutes < 1) return l10n.justNow;
  if (elapsed.inHours < 1) return l10n.minutesAgo(elapsed.inMinutes);
  if (elapsed.inDays < 1) return l10n.hoursAgo(elapsed.inHours);
  if (elapsed.inDays < 7) return l10n.daysAgo(elapsed.inDays);
  return MaterialLocalizations.of(context).formatShortDate(time.toLocal());
}
