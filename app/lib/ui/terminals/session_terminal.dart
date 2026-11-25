/// A session's own terminal: a shell in its folder, kept by herdr-core on
/// the computer and found again each time the session opens it.
library;

import 'dart:async';

import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/terminals/herdr_terminals.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/terminals/terminal_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

Future<void> openSessionTerminal(
  BuildContext context, {
  required HostConnection host,
  required String sessionId,
  required String cwd,
  String agent = '',
}) {
  final repository = TerminalsRepository(HostTerminalLink(host));
  // The page opens at once; finding (or starting) the terminal happens on it.
  final terminal = repository.forSession(sessionId, cwd, agent: agent);
  final prefs = context.read<Preferences>();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HostTerminal(
        host: host,
        build: (online) => FutureBuilder<HerdrTerminal?>(
          future: terminal,
          builder: (context, snapshot) {
            final found = snapshot.data;
            if (found != null) {
              return TerminalPage(
                repository: repository,
                terminal: found,
                online: online,
                fontSize: prefs.terminalFontSize,
                onFontSize: (size) =>
                    unawaited(prefs.setTerminalFontSize(size)),
              );
            }
            return _Opening(
              error: switch (snapshot) {
                AsyncSnapshot(hasError: true, :final error) => '$error',
                AsyncSnapshot(connectionState: ConnectionState.done) =>
                  context.l10n.herdrMissing,
                _ => null,
              },
            );
          },
        ),
      ),
    ),
  );
}

/// The terminal page while its terminal is found, or why it was not.
class _Opening extends StatelessWidget {
  const _Opening({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(backgroundColor: colors.bg, toolbarHeight: 52),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: error == null
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              : Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: context.typo.sansBody.copyWith(color: colors.muted),
                ),
        ),
      ),
    );
  }
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
