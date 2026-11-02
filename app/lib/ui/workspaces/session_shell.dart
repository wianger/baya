/// Adaptive shell: a persistent sidebar on tablets, a drawer on phones.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/workspaces/session_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

class _SessionShellState extends State<SessionShell>
    with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(
      context.read<HomeViewModel>().refreshComputerSessionInventory(
        force: true,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWideLayout(context);
    return _SessionMenu(
      open: wide ? null : () => _scaffold.currentState?.openDrawer(),
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        drawerScrimColor: Colors.black.withValues(alpha: .28),
        drawer: wide
            ? null
            : Drawer(
                width: math.min(352, MediaQuery.sizeOf(context).width - 28),
                backgroundColor: Colors.transparent,
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(28),
                  ),
                ),
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
