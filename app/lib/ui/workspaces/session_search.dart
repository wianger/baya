/// Search, as Claude shows it: a card that rises over the drawer with the
/// field at its top, a round close button beside it, and the sessions
/// below, narrowed as you type.
library;

import 'package:app/data/preferences/preferences.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/widgets/session_list_row.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// The session picked, or null when the search was closed.
Future<HomeItem?> showSessionSearch(BuildContext context) {
  final vm = context.read<HomeViewModel>();
  return Navigator.of(context).push<HomeItem>(
    PageRouteBuilder<HomeItem>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: context.l10n.closeSearchSheet,
      barrierColor: Colors.black.withValues(alpha: .28),
      reverseTransitionDuration: BayaMotion.standard,
      pageBuilder: (_, _, _) => ChangeNotifierProvider<HomeViewModel>.value(
        value: vm,
        child: const _SearchSheet(),
      ),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: BayaMotion.enter,
            reverseCurve: BayaMotion.exit,
          ),
        ),
        child: child,
      ),
    ),
  );
}

class _SearchSheet extends StatefulWidget {
  const _SearchSheet();

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final vm = context.watch<HomeViewModel>();
    final query = _query.trim().toLowerCase();
    final items = vm.workspaceItems
        .where((item) => vm.displayNameOf(item).toLowerCase().contains(query))
        .toList(growable: false);
    final (working, idle) = splitByActivity(
      vm,
      items,
      context.watch<Preferences?>(),
    );
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.only(top: top + 8),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: Material(
          key: const Key('session-search-sheet'),
          color: colors.bg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: BayaSurface(
                        role: BayaSurfaceRole.floating,
                        radius: 26,
                        child: TextField(
                          key: const Key('sidebar-search-field'),
                          autofocus: true,
                          onChanged: (value) => setState(() => _query = value),
                          style: context.typo.sansBody.copyWith(
                            fontSize: BayaType.callout,
                          ),
                          decoration: InputDecoration(
                            hintText: l10n.searchSessions,
                            hintStyle: context.typo.sansBody.copyWith(
                              fontSize: BayaType.callout,
                              color: colors.muted,
                            ),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            prefixIcon: Icon(
                              LucideIcons.search,
                              size: 18,
                              color: colors.muted,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 15,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    BayaCircleButton(
                      key: const Key('sidebar-search-close'),
                      icon: LucideIcons.x,
                      tooltip: l10n.closeSearch,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    if (items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          query.isEmpty
                              ? l10n.noSessionsInWorkspace
                              : l10n.noMatchingSessions,
                          textAlign: TextAlign.center,
                          style: context.typo.sansBody.copyWith(
                            fontSize: BayaType.subhead,
                            color: colors.muted,
                          ),
                        ),
                      )
                    else
                      for (final (title, section) in [
                        (l10n.sessionsWorking, working),
                        (l10n.sessionsIdle, idle),
                      ])
                        if (section.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                            child: Text(
                              title,
                              style: context.typo.sansBody.copyWith(
                                fontSize: BayaType.body,
                                color: colors.muted,
                              ),
                            ),
                          ),
                          for (final item in section)
                            SessionListRow(
                              key: ValueKey(
                                'search-row-${item.peer.remoteEpk}-${item.sessionId}',
                              ),
                              vm: vm,
                              item: item,
                              onOpen: () => Navigator.of(context).pop(item),
                            ),
                        ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
