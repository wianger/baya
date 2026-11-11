import 'dart:async';

import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/preview/preview_proxy.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_sheet.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Lists the web servers running on [host]'s computer; picking one, or
/// typing a port, opens it in [PreviewPage].
Future<void> showPreviewPicker(BuildContext context, HostConnection host) {
  void open(int port) => unawaited(openPreview(context, host, port));
  return showBayaSheet<void>(
    context,
    sheetKey: const Key('preview-picker'),
    title: context.l10n.webPreview,
    subtitle: context.l10n.webPreviewOn(host.host.label),
    builder: (sheetContext) => _PortPicker(
      host: host,
      onOpen: (port) {
        Navigator.of(sheetContext).pop();
        open(port);
      },
    ),
  );
}

/// Opens the site on [port] of [host]'s computer, at [path].
Future<void> openPreview(
  BuildContext context,
  HostConnection host,
  int port, {
  String path = '/',
}) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute<void>(
    builder: (_) => PreviewPage(host: host, port: port, path: path),
  ),
);

class _PortPicker extends StatefulWidget {
  const _PortPicker({required this.host, required this.onOpen});
  final HostConnection host;
  final ValueChanged<int> onOpen;

  @override
  State<_PortPicker> createState() => _PortPickerState();
}

class _PortPickerState extends State<_PortPicker> {
  late Future<List<PreviewPort>> _ports = previewPorts(widget.host);
  final _port = TextEditingController();

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  void _openTyped() {
    final port = int.tryParse(_port.text.trim());
    if (port != null && port > 0 && port < 65536) widget.onOpen(port);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder(
          future: _ports,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      l10n.lookingForWebServers,
                      style: TextStyle(color: colors.muted),
                    ),
                  ],
                ),
              );
            }
            final ports = snapshot.data ?? const <PreviewPort>[];
            if (snapshot.hasError || ports.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  snapshot.hasError
                      ? '${snapshot.error}'
                      : l10n.noWebServersFound,
                  style: TextStyle(
                    color: snapshot.hasError ? colors.error : colors.muted,
                    height: 1.4,
                  ),
                ),
              );
            }
            return BayaGroup(
              children: [
                for (final (index, port) in ports.indexed)
                  BayaReveal(
                    delay: BayaReveal.stagger(index),
                    child: BayaRow(
                      key: ValueKey('preview-port-${port.port}'),
                      icon: port.html ? LucideIcons.globe : LucideIcons.server,
                      label: port.title.isNotEmpty
                          ? port.title
                          : 'localhost:${port.port}',
                      subtitle: port.title.isNotEmpty
                          ? 'localhost:${port.port}'
                          : 'HTTP ${port.status}',
                      monospaceSubtitle: true,
                      chevron: true,
                      onTap: () => widget.onOpen(port.port),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('preview-port-field'),
                controller: _port,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: context.typo.mono.copyWith(fontSize: 14),
                decoration: InputDecoration(
                  labelText: l10n.port,
                  hintText: '5173',
                ),
                onSubmitted: (_) => _openTyped(),
              ),
            ),
            const SizedBox(width: 10),
            BayaButton(
              key: const Key('preview-open-port'),
              onPressed: _openTyped,
              label: Text(l10n.open),
              minimumSize: const Size(88, 52),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() {
              _ports = previewPorts(widget.host);
            }),
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: Text(l10n.lookAgain),
          ),
        ),
      ],
    );
  }
}

/// A site running on the computer, in a WebView on the phone.
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.host,
    required this.port,
    this.path = '/',
  });

  final HostConnection host;
  final int port;
  final String path;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  PreviewProxy? _proxy;
  WebViewController? _web;
  String? _error;
  String _title = '';
  String _path = '/';
  int _progress = 0;
  bool _canGoBack = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _path = widget.path;
    unawaited(_start());
  }

  Future<void> _start() async {
    setState(() => _error = null);
    PreviewProxy? proxy;
    try {
      proxy = await PreviewProxy.open(widget.host, widget.port);
      if (_closed) return unawaited(proxy.close());
      final web = WebViewController();
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url != null && mounted) {
              setState(() => _path = _pathOf(Uri.parse(url)));
            }
          },
          onPageFinished: (_) => unawaited(_refreshState()),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() => _error = error.description);
            }
          },
          onNavigationRequest: (request) {
            // Links off the site open in the phone's browser.
            final uri = Uri.parse(request.url);
            if (uri.host == '127.0.0.1' || !uri.hasScheme) {
              return NavigationDecision.navigate;
            }
            unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
            return NavigationDecision.prevent;
          },
        ),
      );
      await web.loadRequest(proxy.url(widget.path));
      if (!mounted) return unawaited(proxy.close());
      setState(() {
        _proxy = proxy;
        _web = web;
      });
    } catch (error) {
      // A proxy that never reached the page is ours to close.
      if (proxy != null && !identical(proxy, _proxy)) unawaited(proxy.close());
      if (mounted) setState(() => _error = '$error');
    }
  }

  static String _pathOf(Uri uri) =>
      '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';

  Future<void> _refreshState() async {
    final web = _web;
    if (web == null) return;
    final title = await web.getTitle() ?? '';
    final back = await web.canGoBack();
    if (mounted) {
      setState(() {
        _title = title;
        _canGoBack = back;
      });
    }
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_proxy?.close());
    super.dispose();
  }

  String get _address => 'localhost:${widget.port}$_path';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final web = _web;
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || web == null) return;
        await web.goBack();
        await _refreshState();
      },
      child: Scaffold(
        backgroundColor: colors.bg,
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _title.isNotEmpty ? _title : context.l10n.webPreview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typo.sansBody.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typo.monoSmall.copyWith(color: colors.muted),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: context.l10n.copyAddress,
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: 'http://$_address')),
              icon: const Icon(LucideIcons.copy, size: 19),
            ),
            IconButton(
              key: const Key('preview-reload'),
              tooltip: context.l10n.reload,
              onPressed: web == null
                  ? _start
                  : () {
                      setState(() => _error = null);
                      unawaited(web.reload());
                    },
              icon: const Icon(LucideIcons.rotateCw, size: 19),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(2),
            child: AnimatedOpacity(
              opacity: _progress > 0 && _progress < 100 ? 1 : 0,
              duration: BayaMotion.standard,
              child: LinearProgressIndicator(
                minHeight: 2,
                value: _progress / 100,
                color: colors.accent,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
        ),
        body: Stack(
          children: [
            if (web != null) WebViewWidget(controller: web),
            if (web == null && _error == null)
              const Center(
                child: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (_error case final error?)
              Positioned.fill(
                child: ColoredBox(
                  color: colors.bg,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.globe,
                            size: 28,
                            color: colors.muted,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            context.l10n.previewDidNotLoad(widget.port),
                            textAlign: TextAlign.center,
                            style: context.typo.sansBody.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            error,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colors.muted, height: 1.4),
                          ),
                          const SizedBox(height: 18),
                          BayaButton(
                            onPressed: web == null
                                ? _start
                                : () {
                                    setState(() => _error = null);
                                    unawaited(web.reload());
                                  },
                            label: Text(context.l10n.retry),
                          ),
                        ],
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
