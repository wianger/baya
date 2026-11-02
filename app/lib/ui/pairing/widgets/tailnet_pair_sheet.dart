import 'package:app/data/preferences/preferences.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/pairing/tailnet_pairing.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Pair by typing the computer's Tailscale name instead of scanning.
/// [onSubmit] receives the pairing code, exactly as a scan would.
Future<void> showTailnetPairSheet(
  BuildContext context, {
  required void Function(String raw) onSubmit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => BayaSurface(
      role: BayaSurfaceRole.overlay,
      radius: 28,
      elevated: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: _TailnetPairBody(onSubmit: onSubmit),
      ),
    ),
  );
}

class _TailnetPairBody extends StatefulWidget {
  const _TailnetPairBody({required this.onSubmit});
  final void Function(String raw) onSubmit;

  @override
  State<_TailnetPairBody> createState() => _TailnetPairBodyState();
}

class _TailnetPairBodyState extends State<_TailnetPairBody> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Hosts found on the typed computer when there is more than one.
  List<TailnetHost>? _choices;

  Future<void> _pair() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    await _guard(name, () async {
      final hosts = await discoverTailnetHosts(
        name,
        tailnetSuffix: _tailnetSuffix(),
      );
      if (hosts.length == 1) return _pairWith(hosts.single, name);
      if (mounted) setState(() => _choices = hosts);
    });
  }

  Future<void> _pairWith(TailnetHost host, String name) =>
      _guard(name, () async {
        final code = await fetchTailnetPairingCode(host);
        if (!mounted) return;
        Navigator.of(context).pop();
        widget.onSubmit(code);
      });

  /// Runs [action] with the busy state and turns failures into messages.
  Future<void> _guard(String name, Future<void> Function() action) async {
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on TailnetPairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = switch (e.reason) {
          TailnetPairingFailure.notYourAccount => l10n.tailnetNotYourAccount,
          TailnetPairingFailure.unreachable => l10n.tailnetUnreachable(name),
          TailnetPairingFailure.notReady => l10n.tailnetNotReady,
          TailnetPairingFailure.unknownTailnet => l10n.tailnetTypeFullName(
            name,
          ),
        };
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The tailnet of earlier pairings completes short names.
  String? _tailnetSuffix() {
    try {
      return context.read<Preferences>().tailnetDomain;
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.pairOverTailscale, style: context.typo.title),
          const SizedBox(height: 8),
          Text(
            l10n.pairOverTailscaleHint,
            style: context.typo.sansBody.copyWith(color: colors.muted),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('tailnet-name'),
            controller: _name,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _pair(),
            decoration: InputDecoration(
              hintText: l10n.computerNameHint,
              errorText: _error,
              errorMaxLines: 3,
              prefixIcon: const Icon(LucideIcons.monitor),
            ),
          ),
          if (_choices case final hosts?) ...[
            const SizedBox(height: 12),
            Text(l10n.chooseBaya, style: context.typo.sansBody),
            for (final host in hosts)
              ListTile(
                key: Key('tailnet-host-${host.label}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  host.label == 'windows'
                      ? LucideIcons.appWindow
                      : LucideIcons.terminal,
                ),
                title: Text(host.name),
                enabled: !_busy,
                onTap: () => _pairWith(host, _name.text.trim()),
              ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: BayaButton(
              buttonKey: const Key('tailnet-pair'),
              onPressed: _busy ? null : _pair,
              label: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.pair),
            ),
          ),
        ],
      ),
    );
  }
}
