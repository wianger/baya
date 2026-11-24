/// A session's own terminal: a shell in its folder, kept by herdr-core on
/// the computer and found again each time the session opens it.
library;

import 'dart:async';

import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/terminals/herdr_terminals.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/terminals/terminal_page.dart';
import 'package:app/ui/terminals/terminals_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

Future<void> openSessionTerminal(
  BuildContext context, {
  required HostConnection host,
  required String sessionId,
  required String cwd,
}) async {
  final repository = TerminalsRepository(HostTerminalLink(host));
  final HerdrTerminal? terminal;
  try {
    terminal = await repository.forSession(sessionId, cwd);
  } catch (error) {
    if (context.mounted) await showBayaError(context, message: '$error');
    return;
  }
  if (!context.mounted) return;
  if (terminal == null) {
    await showBayaError(context, message: context.l10n.herdrMissing);
    return;
  }
  final prefs = context.read<Preferences>();
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HostTerminal(
        host: host,
        build: (online) => TerminalPage(
          repository: repository,
          terminal: terminal!,
          online: online,
          fontSize: prefs.terminalFontSize,
          onFontSize: (size) => unawaited(prefs.setTerminalFontSize(size)),
          onAllTerminals: (pageContext) => Navigator.of(pageContext).push(
            MaterialPageRoute<void>(
              builder: (_) => TerminalsPage(
                launch: TerminalsLaunch(
                  hostId: host.key,
                  label: host.host.label,
                ),
                repository: repository,
                online: online,
                fontSize: prefs.terminalFontSize,
                onFontSize: (size) =>
                    unawaited(prefs.setTerminalFontSize(size)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Gives a terminal page the computer's online state, for as long as it
/// is open.
class HostTerminal extends StatefulWidget {
  const HostTerminal({super.key, required this.host, required this.build});

  final HostConnection host;
  final Widget Function(HostOnline online) build;

  @override
  State<HostTerminal> createState() => _HostTerminalState();
}

class _HostTerminalState extends State<HostTerminal> {
  late final _online = HostOnline(widget.host);

  @override
  void dispose() {
    _online.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.build(_online);
}
