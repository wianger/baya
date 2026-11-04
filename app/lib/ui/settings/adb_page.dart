import 'dart:async';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/pairing/tailnet_pairing.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_group.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/copy_button.dart';
import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Lets a computer's agents use this phone through adb: Wireless debugging
/// on the phone, paired and connected by the computer over the tailnet.
class AdbPage extends StatefulWidget {
  const AdbPage({super.key, this.phoneAddress = tailnetAddressOfThisPhone});

  /// This phone's address as the computer reaches it.
  final Future<String?> Function() phoneAddress;

  @override
  State<AdbPage> createState() => _AdbPageState();
}

class _AdbPageState extends State<AdbPage> {
  final _ip = TextEditingController();
  final _pairPort = TextEditingController();
  final _code = TextEditingController();
  final _port = TextEditingController();
  String? _hostKey;
  Future<Json>? _status;
  String? _busy;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.phoneAddress().then((ip) {
        if (mounted && ip != null && _ip.text.isEmpty) _ip.text = ip;
      }),
    );
  }

  @override
  void dispose() {
    for (final field in [_ip, _pairPort, _code, _port]) {
      field.dispose();
    }
    super.dispose();
  }

  HostConnection? _host(List<HostConnection> online) =>
      online.where((h) => h.key == _hostKey).firstOrNull ?? online.firstOrNull;

  void _refresh(HostConnection host) => setState(() {
    _status = host.call('_baya/adb_status');
  });

  Future<void> _run(
    HostConnection host,
    String step,
    String method,
    Json params,
    String done,
  ) async {
    setState(() {
      _busy = step;
      _message = null;
    });
    try {
      await host.call(method, params, const Duration(seconds: 45));
      if (!mounted) return;
      setState(() {
        _failed = false;
        _message = done;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _message = error is RpcError ? error.message : '$error';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = null);
        _refresh(host);
      }
    }
  }

  String get _address => '${_ip.text.trim()}:${_port.text.trim()}';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final online = context.watch<Hosts>().all.where((h) => h.isOnline).toList();
    final host = _host(online);
    if (host != null) _status ??= host.call('_baya/adb_status');
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(context.l10n.phoneForAgents),
      ),
      body: SafeArea(
        child: host == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    context.l10n.noComputerOnline,
                    textAlign: TextAlign.center,
                    style: context.typo.sansBody.copyWith(color: colors.muted),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 36),
                children: [
                  Text(
                    context.l10n.phoneForAgentsHint,
                    style: context.typo.sansBody.copyWith(
                      color: colors.muted2,
                      height: 1.5,
                    ),
                  ),
                  if (online.length > 1) ...[
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final h in online)
                          ChoiceChip(
                            label: Text(h.host.label),
                            selected: h.key == host.key,
                            onSelected: (_) => setState(() {
                              _hostKey = h.key;
                              _status = null;
                            }),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  _StatusCard(
                    key: ValueKey(host.key),
                    status: _status,
                    ip: _ip.text.trim(),
                    computer: host.host.label,
                    onDisconnect: (serial) => _run(
                      host,
                      'disconnect',
                      '_baya/adb_disconnect',
                      {'address': serial},
                      context.l10n.adbDisconnected,
                    ),
                  ),
                  const SizedBox(height: 22),
                  _Step(
                    number: 1,
                    title: context.l10n.adbStepEnable,
                    body: context.l10n.adbStepEnableHint,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('adb-open-developer'),
                        onPressed: () => AppSettings.openAppSettings(
                          type: AppSettingsType.developer,
                        ),
                        icon: const Icon(LucideIcons.settings2, size: 16),
                        label: Text(context.l10n.openDeveloperOptions),
                      ),
                    ),
                  ),
                  _Step(
                    number: 2,
                    title: context.l10n.adbStepPair,
                    body: context.l10n.adbStepPairHint,
                    child: Column(
                      children: [
                        _field(
                          _ip,
                          context.l10n.phoneAddress,
                          key: 'adb-ip',
                          number: false,
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: _field(
                                _pairPort,
                                context.l10n.pairingPort,
                                key: 'adb-pair-port',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _field(
                                _code,
                                context.l10n.pairingCode,
                                key: 'adb-code',
                              ),
                            ),
                          ],
                        ),
                        _action(
                          key: 'adb-pair',
                          label: context.l10n.pair,
                          busy: _busy == 'pair',
                          onPressed: () => _run(
                            host,
                            'pair',
                            '_baya/adb_pair',
                            {
                              'address':
                                  '${_ip.text.trim()}:${_pairPort.text.trim()}',
                              'code': _code.text.trim(),
                            },
                            context.l10n.adbPaired,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Step(
                    number: 3,
                    title: context.l10n.adbStepConnect,
                    body: context.l10n.adbStepConnectHint,
                    child: Column(
                      children: [
                        _field(_port, context.l10n.port, key: 'adb-port'),
                        _action(
                          key: 'adb-connect',
                          label: context.l10n.connect,
                          busy: _busy == 'connect',
                          onPressed: () => _run(
                            host,
                            'connect',
                            '_baya/adb_connect',
                            {'address': _address},
                            context.l10n.adbConnected(_address),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_message case final message?)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        message,
                        key: const Key('adb-message'),
                        style: context.typo.sansBody.copyWith(
                          color: _failed ? colors.error : colors.success,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    required String key,
    bool number = true,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      key: Key(key),
      controller: controller,
      keyboardType: number
          ? TextInputType.number
          : const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: number
          ? [FilteringTextInputFormatter.digitsOnly]
          : [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F.:]'))],
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (_) => setState(() {}),
    ),
  );

  Widget _action({
    required String key,
    required String label,
    required bool busy,
    required VoidCallback onPressed,
  }) => Align(
    alignment: Alignment.centerRight,
    child: FilledButton(
      key: Key(key),
      onPressed: _busy == null ? onPressed : null,
      child: busy
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    ),
  );
}

/// What the computer's adb sees: none at all, or this phone connected.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    super.key,
    required this.status,
    required this.ip,
    required this.computer,
    required this.onDisconnect,
  });

  final Future<Json>? status;
  final String ip;
  final String computer;
  final ValueChanged<String> onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return BayaSurface(
      role: BayaSurfaceRole.content,
      radius: 18,
      elevated: false,
      padding: const EdgeInsets.all(14),
      child: FutureBuilder<Json>(
        future: status,
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return Row(
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(context.l10n.adbChecking(computer)),
              ],
            );
          }
          if (data['adb'] == null) {
            return _line(
              context,
              LucideIcons.triangleAlert,
              colors.warning,
              context.l10n.adbMissing(computer),
            );
          }
          final devices = (data['devices'] as List)
              .cast<Map<String, dynamic>>();
          final mine = devices
              .where(
                (d) =>
                    ip.isNotEmpty && (d['serial'] as String).startsWith('$ip:'),
              )
              .where((d) => d['state'] == 'device')
              .firstOrNull;
          if (mine == null) {
            return _line(
              context,
              LucideIcons.smartphone,
              colors.muted,
              context.l10n.adbNotConnected(computer),
            );
          }
          final serial = mine['serial'] as String;
          final hint = context.l10n.adbAgentHint(serial);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _line(
                context,
                LucideIcons.circleCheck,
                colors.success,
                context.l10n.adbConnectedTo(computer, serial),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      hint,
                      key: const Key('adb-agent-hint'),
                      style: context.typo.monoSmall.copyWith(
                        color: colors.muted2,
                      ),
                    ),
                  ),
                  BayaCopyButton(text: hint),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('adb-disconnect'),
                  onPressed: () => onDisconnect(serial),
                  child: Text(context.l10n.disconnect),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, Color color, String text) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: context.typo.sansBody)),
        ],
      );
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.body,
    required this.child,
  });

  final int number;
  final String title;
  final String body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BayaSectionLabel('$number · $title'),
          Text(
            body,
            style: context.typo.sansBody.copyWith(
              color: colors.muted2,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
