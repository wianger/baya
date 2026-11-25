/// The home: the menu in the corner, the mark and its name in the middle.
library;

import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/ui/core/branding/baya_intro.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class SessionWelcome extends StatelessWidget {
  const SessionWelcome({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final menu = SessionShell.menuOf(context);
    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 68,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  if (menu != null)
                    BayaCircleButton(
                      key: const Key('overview-menu'),
                      icon: LucideIcons.textAlignStart,
                      tooltip: context.l10n.openNavigation,
                      onPressed: menu,
                    ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Column(
                  key: const Key('workspace-overview'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppMark(size: kHomeMarkSize),
                    const SizedBox(height: kHomeMarkGap),
                    Text(
                      kAppName,
                      key: const Key('overview-wordmark'),
                      style: brandDisplayTextStyle(
                        fontSize: kHomeWordmarkSize,
                        color: colors.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
