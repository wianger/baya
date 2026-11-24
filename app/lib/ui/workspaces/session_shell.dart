/// Adaptive shell: a persistent sidebar on tablets, a drawer on phones.
library;

import 'dart:math' as math;

import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/workspaces/session_sidebar.dart';
import 'package:flutter/material.dart';

export 'package:app/ui/workspaces/session_actions.dart'
    show showCreateWorkspace;
export 'package:app/ui/workspaces/session_overview.dart' show SessionWelcome;
export 'package:app/ui/workspaces/session_sidebar.dart' show SessionSidebar;

class SessionShell extends StatefulWidget {
  const SessionShell({super.key, required this.child});
  final Widget child;
  static VoidCallback? menuOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SessionMenu>()?.open;
  @override
  State<SessionShell> createState() => _SessionShellState();
}

class _SessionShellState extends State<SessionShell> {
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    return _SessionMenu(
      open: wide ? null : () => _scaffold.currentState?.openDrawer(),
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        drawerScrimColor: Colors.black.withValues(alpha: .24),
        drawer: wide
            ? null
            : Drawer(
                // DeepSeek's drawer: most of the width, square-edged.
                width: math.min(336, MediaQuery.sizeOf(context).width * .82),
                backgroundColor: Colors.transparent,
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                shape: const RoundedRectangleBorder(),
                child: SessionSidebar(
                  close: () => _scaffold.currentState?.closeDrawer(),
                ),
              ),
        body: BayaBackdrop(
          child: Row(
            children: [
              if (wide) ...[
                const SizedBox(width: 304, child: SessionSidebar()),
                VerticalDivider(width: 1, color: context.colors.border),
              ],
              Expanded(child: widget.child),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionMenu extends InheritedWidget {
  const _SessionMenu({required this.open, required super.child});
  final VoidCallback? open;
  @override
  bool updateShouldNotify(_SessionMenu oldWidget) => open != oldWidget.open;
}
