/// The computer's terminals, as herdr-core keeps them: agents in their own
/// TUIs, shells, servers. The ones waiting for the user come first; any one
/// opens full screen, and a new shell or agent starts from here.
library;

import 'dart:async';

import 'package:app/data/terminals/herdr_terminals.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/terminals/terminal_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class TerminalsLaunch {
  const TerminalsLaunch({required this.hostId, required this.label});
  final String hostId;
  final String label;
}

class TerminalsPage extends StatefulWidget {
  const TerminalsPage({
    super.key,
    required this.launch,
    required this.repository,
    this.online,
    this.fontSize = 13,
    this.onFontSize,
  });

  final TerminalsLaunch launch;
  final TerminalsRepository repository;
  final ValueListenable<bool>? online;

  /// The terminal text size, kept across terminals and visits.
  final double fontSize;
  final ValueChanged<double>? onFontSize;

  @override
  State<TerminalsPage> createState() => _TerminalsPageState();
}

class _TerminalsPageState extends State<TerminalsPage> {
  TerminalList? _list;
  Object? _error;
  bool _starting = false;
  late double _fontSize = widget.fontSize;
  StreamSubscription<void>? _changes;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _changes = widget.repository.changes.listen((_) {
      _settle?.cancel();
      _settle = Timer(const Duration(milliseconds: 120), _load);
    });
    widget.online?.addListener(_onlineChanged);
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    _settle?.cancel();
    widget.online?.removeListener(_onlineChanged);
    super.dispose();
  }

  void _onlineChanged() {
    if (widget.online?.value ?? false) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final list = await widget.repository.list();
      if (!mounted) return;
      setState(() {
        _list = list;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _open(HerdrTerminal terminal) async {
    unawaited(HapticFeedback.selectionClick());
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalPage(
          repository: widget.repository,
          terminal: terminal,
          online: widget.online,
          fontSize: _fontSize,
          onFontSize: (size) {
            _fontSize = size;
            widget.onFontSize?.call(size);
          },
        ),
      ),
    );
    if (mounted) unawaited(_load());
  }

  Future<void> _start({String? line}) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final terminal = await widget.repository.run(line: line);
      if (mounted) await _open(terminal);
    } catch (error) {
      if (mounted) await showBayaError(context, message: '$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _newMenu() async {
    final line = await showBayaSheet<String>(
      context,
      title: context.l10n.newTerminal,
      builder: (_) => const _NewTerminalSheet(),
    );
    if (line == null || !mounted) return;
    await _start(line: line.isEmpty ? null : line);
  }

  Future<void> _remove(HerdrTerminal terminal) async {
    try {
      await (terminal.live
          ? widget.repository.kill(terminal.address)
          : widget.repository.remove(terminal.address));
    } catch (error) {
      if (mounted) await showBayaError(context, message: '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final list = _list;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: BayaHeader(title: l10n.terminals, subtitle: widget.launch.label),
      floatingActionButton: list?.available ?? false
          ? FloatingActionButton.extended(
              key: const Key('terminal-new'),
              onPressed: _starting ? null : _newMenu,
              backgroundColor: colors.text,
              foregroundColor: colors.bg,
              elevation: 0,
              highlightElevation: 0,
              shape: const StadiumBorder(),
              icon: _starting
                  ? SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: colors.bg,
                      ),
                    )
                  : const Icon(LucideIcons.plus, size: 18),
              label: Text(l10n.newTerminal),
            )
          : null,
      body: RefreshIndicator(
        color: colors.text,
        onRefresh: _load,
        child: _body(context, list),
      ),
    );
  }

  Widget _body(BuildContext context, TerminalList? list) {
    final colors = context.colors;
    final l10n = context.l10n;
    if (list == null && _error == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 1.6));
    }
    if (list == null) {
      return _Message(
        icon: LucideIcons.circleAlert,
        text: '$_error',
        action: TextButton(onPressed: _load, child: Text(l10n.retry)),
      );
    }
    if (!list.available) {
      return _Message(
        key: const Key('terminals-no-herdr'),
        icon: LucideIcons.squareTerminal,
        text: l10n.herdrMissing,
        detail: 'curl -fsSL https://releases.herdr.dev/core/install.sh | sh',
        action: TextButton(onPressed: _load, child: Text(l10n.refresh)),
      );
    }
    final needs = [
      for (final t in list.terminals)
        if (t.needsYou) t,
    ];
    final live = [
      for (final t in list.terminals)
        if (t.live && !t.needsYou) t,
    ];
    final ended = [
      for (final t in list.terminals)
        if (!t.live) t,
    ];
    if (list.terminals.isEmpty) {
      return _Message(icon: LucideIcons.squareTerminal, text: l10n.noTerminals);
    }
    Widget group(String label, List<HerdrTerminal> terminals) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BayaSectionLabel(label, top: 22),
        BayaReveal(
          child: BayaGroup(
            children: [
              for (final terminal in terminals)
                _TerminalRow(
                  terminal: terminal,
                  onTap: () => _open(terminal),
                  onRemove: () => _remove(terminal),
                ),
            ],
          ),
        ),
      ],
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const Key('terminals'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            Text(
              l10n.terminalsHint,
              style: TextStyle(color: colors.muted, height: 1.4),
            ),
            if (needs.isNotEmpty) group(l10n.terminalsNeedYou, needs),
            if (live.isNotEmpty) group(l10n.terminalsRunning, live),
            if (ended.isNotEmpty) group(l10n.terminalsEnded, ended),
          ],
        ),
      ),
    );
  }
}

class _TerminalRow extends StatelessWidget {
  const _TerminalRow({
    required this.terminal,
    required this.onTap,
    required this.onRemove,
  });

  final HerdrTerminal terminal;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final status = terminal.status;
    final folder = terminal.folder
        .split(RegExp(r'[/\\]'))
        .lastWhere((part) => part.isNotEmpty, orElse: () => terminal.folder);
    final word = !terminal.live
        ? l10n.terminalEnded(terminal.reason ?? 'exited')
        : switch (status?.state) {
            'blocked' => status?.message ?? l10n.terminalStateBlocked,
            'working' => l10n.terminalStateWorking,
            'done' => l10n.terminalStateDone,
            'error' => l10n.terminalStateError,
            'idle' => l10n.terminalStateIdle,
            _ => null,
          };
    return Dismissible(
      key: ValueKey('terminal-${terminal.address}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        onRemove();
        return !terminal.live;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: colors.error,
        child: Icon(
          terminal.live ? LucideIcons.squareX : LucideIcons.trash2,
          color: colors.bg,
          size: 18,
        ),
      ),
      child: BayaRow(
        key: ValueKey('terminal-row-${terminal.address}'),
        icon: terminal.needsYou
            ? LucideIcons.messageCircleQuestionMark
            : (status?.working ?? false)
            ? LucideIcons.loaderCircle
            : LucideIcons.squareTerminal,
        spinning: terminal.live && (status?.working ?? false),
        highlighted: terminal.needsYou,
        label: terminal.label,
        subtitle: [
          terminal.app,
          if (folder.isNotEmpty) folder,
          ?word,
        ].join(' · '),
        trailing: Text(
          terminal.address,
          style: context.typo.monoSmall.copyWith(
            fontSize: BayaType.caption,
            color: colors.muted,
          ),
        ),
        chevron: true,
        onTap: onTap,
      ),
    );
  }
}

/// A shell, or a line to run: an agent's own TUI, a server.
class _NewTerminalSheet extends StatefulWidget {
  const _NewTerminalSheet();

  @override
  State<_NewTerminalSheet> createState() => _NewTerminalSheetState();
}

class _NewTerminalSheetState extends State<_NewTerminalSheet> {
  final _line = TextEditingController();

  static const _suggestions = ['claude', 'codex', 'pi', 'agy', 'htop'];

  @override
  void dispose() {
    _line.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BayaGroup(
            children: [
              BayaRow(
                key: const Key('terminal-new-shell'),
                icon: LucideIcons.squareTerminal,
                label: l10n.newShell,
                subtitle: l10n.newShellHint,
                onTap: () => Navigator.of(context).pop(''),
              ),
            ],
          ),
          const SizedBox(height: 14),
          BayaSurface(
            role: BayaSurfaceRole.control,
            radius: 22,
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Text(
                  r'$',
                  style: context.typo.mono.copyWith(color: colors.muted),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const Key('terminal-new-line'),
                    controller: _line,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.go,
                    style: context.typo.mono.copyWith(
                      fontSize: BayaType.subhead,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: l10n.runCommandHint,
                      hintStyle: TextStyle(color: colors.muted),
                    ),
                    onSubmitted: (value) {
                      if (value.trim().isNotEmpty) {
                        Navigator.of(context).pop(value.trim());
                      }
                    },
                  ),
                ),
                IconButton(
                  key: const Key('terminal-new-run'),
                  tooltip: l10n.run,
                  icon: const Icon(LucideIcons.cornerDownLeft, size: 18),
                  onPressed: () {
                    final value = _line.text.trim();
                    if (value.isNotEmpty) Navigator.of(context).pop(value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in _suggestions)
                ActionChip(
                  label: Text(
                    suggestion,
                    style: context.typo.monoSmall.copyWith(
                      fontSize: BayaType.footnote,
                      color: colors.text,
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(suggestion),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String text;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      children: [
        Icon(icon, size: 30, color: colors.muted),
        const SizedBox(height: 14),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.muted2, height: 1.45),
        ),
        if (detail != null) ...[
          const SizedBox(height: 12),
          SelectableText(
            detail!,
            textAlign: TextAlign.center,
            style: context.typo.monoSmall.copyWith(
              fontSize: BayaType.caption,
              color: colors.text,
            ),
          ),
        ],
        if (action != null) ...[
          const SizedBox(height: 8),
          Center(child: action),
        ],
      ],
    );
  }
}
