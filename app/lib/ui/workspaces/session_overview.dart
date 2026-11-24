/// The workspace overview shown when no chat is open.
library;

import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class SessionWelcome extends StatelessWidget {
  const SessionWelcome({super.key});

  /// The home: the menu icon in the corner, and the mark with "Baya" in
  /// the middle. Everything else is in the drawer.
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final menu = SessionShell.menuOf(context);
    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Column(
                key: const Key('workspace-overview'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppMark(size: 88, tile: true),
                  const SizedBox(height: 18),
                  Text(
                    kAppName,
                    key: const Key('overview-wordmark'),
                    style: brandDisplayTextStyle(
                      fontSize: 54,
                      color: colors.text,
                    ),
                  ),
                ],
              ),
            ),
            if (menu != null)
              Positioned(
                left: 16,
                top: 8,
                child: BayaSurface(
                  role: BayaSurfaceRole.floating,
                  radius: 26,
                  child: SizedBox.square(
                    dimension: 52,
                    child: IconButton(
                      key: const Key('overview-menu'),
                      onPressed: menu,
                      tooltip: context.l10n.openNavigation,
                      icon: Icon(
                        LucideIcons.textAlignStart,
                        size: 21,
                        color: colors.text,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
