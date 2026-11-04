// Web preview, the phone's half: a small HTTP server on this phone's
// loopback that the WebView loads. It forwards each request, WebSockets
// included, over Tailscale's HTTPS to the computer's Baya, adding the
// preview's token; Baya passes it on to the port on that computer (see the
// host's src/preview/preview.ts).
//
// Serving the page from its own origin keeps a site's absolute paths
// (`/src/main.ts`, `/@vite/client`) working, which a path under the
// computer's address would break.

import 'dart:async';
import 'dart:io';

import 'package:app/data/hosts/host_connection.dart';
import 'package:flutter/foundation.dart';

/// A web server on a computer, as `_baya/preview_ports` lists it.
class PreviewPort {
  const PreviewPort({
    required this.port,
    required this.status,
    required this.title,
    required this.html,
  });

  factory PreviewPort.fromJson(Map<String, dynamic> json) => PreviewPort(
    port: (json['port'] as num).toInt(),
    status: (json['status'] as num?)?.toInt() ?? 0,
    title: json['title'] as String? ?? '',
    html: json['html'] == true,
  );

  final int port;
  final int status;
  final String title;
  final bool html;
}

/// The web servers running on [host].
Future<List<PreviewPort>> previewPorts(HostConnection host) async {
  final result = await host.call('_baya/preview_ports', const {});
  return [
    for (final port in (result['ports'] as List? ?? const []))
      PreviewPort.fromJson((port as Map).cast<String, dynamic>()),
  ];
}

/// `localhost` links an agent writes (`http://localhost:5173/about`): the
/// port, or null for anything else.
int? localPort(Uri uri) {
  const local = {'localhost', '127.0.0.1', '0.0.0.0', '::1', '[::1]'};
  if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
  if (!local.contains(uri.host)) return null;
  return uri.hasPort ? uri.port : (uri.isScheme('https') ? 443 : 80);
}

/// Headers that belong to one hop, never forwarded.
const _hopHeaders = {
  'connection',
  'keep-alive',
  'proxy-connection',
  'transfer-encoding',
  'te',
  'trailer',
  'upgrade',
  'host',
  'content-length',
};

/// Makes a cookie set for the computer's site keep working on the
/// phone's `http://127.0.0.1` origin.
String loopbackCookie(String cookie) => cookie
    .split(';')
    .where((part) {
      final name = part.trim().toLowerCase();
      return name != 'secure' &&
          !name.startsWith('domain=') &&
          !name.startsWith('samesite=none');
    })
    .join(';');

class PreviewProxy {
  PreviewProxy._(this.port, this._server, this._upstream, this._onClose);

  /// Opens a preview of [port] on [host]'s computer.
  static Future<PreviewProxy> open(HostConnection host, int port) async {
    final result = await host.call('_baya/preview_open', {'port': port});
    return serve(
      port: port,
      origin: Uri.parse(host.host.endpoint),
      path: result['path'] as String,
      header: result['header'] as String,
      token: result['token'] as String,
      onClose: () {
        if (!host.isOnline) return;
        unawaited(
          host
              .call('_baya/preview_close', {'port': port})
              .then((_) {}, onError: (_) {}),
        );
      },
    );
  }

  /// Serves [port]'s preview from [origin][path] (the host's preview
  /// route), sending [token] in [header].
  static Future<PreviewProxy> serve({
    required int port,
    required Uri origin,
    required String path,
    required String header,
    required String token,
    VoidCallback? onClose,
  }) async {
    final upstream = _Upstream(
      origin: Uri(scheme: origin.scheme, host: origin.host, port: origin.port),
      path: path,
      header: header,
      token: token,
      client: HttpClient()..autoUncompress = false,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = PreviewProxy._(port, server, upstream, onClose);
    server.listen(proxy._serve);
    return proxy;
  }

  /// The port previewed on the computer.
  final int port;
  final HttpServer _server;
  final _Upstream _upstream;
  final VoidCallback? _onClose;

  /// What the WebView loads; [path] is the page on the computer's site.
  Uri url([String path = '/']) =>
      Uri.parse('http://127.0.0.1:${_server.port}$path');

  Future<void> _serve(HttpRequest request) async {
    try {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        await _socket(request);
      } else {
        await _forward(request);
      }
    } catch (error) {
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..headers.contentType = ContentType.text
          ..write('Baya could not reach the computer: $error');
        await request.response.close();
      } catch (_) {
        // The response had already started.
      }
    }
  }

  Future<void> _forward(HttpRequest request) async {
    final upstream = await _upstream.client.openUrl(
      request.method,
      _upstream.uri(request.uri, websocket: false),
    );
    upstream.followRedirects = false;
    // `set`, not `add`: the client has its own User-Agent and
    // Accept-Encoding, which the WebView's replace.
    request.headers.forEach((name, values) {
      if (_hopHeaders.contains(name)) return;
      upstream.headers.set(name, values, preserveHeaderCase: true);
    });
    upstream.headers.set(_upstream.header, _upstream.token);
    if (request.contentLength >= 0) {
      upstream.contentLength = request.contentLength;
    }
    await upstream.addStream(request);
    final reply = await upstream.close();
    final response = request.response
      ..statusCode = reply.statusCode
      ..reasonPhrase = reply.reasonPhrase;
    response.headers.clear();
    reply.headers.forEach((name, values) {
      if (_hopHeaders.contains(name)) return;
      for (final value in values) {
        response.headers.add(
          name,
          name == 'set-cookie' ? loopbackCookie(value) : value,
          preserveHeaderCase: true,
        );
      }
    });
    // clear() also dropped the framing: say how the body ends.
    if (reply.contentLength >= 0) {
      response.contentLength = reply.contentLength;
    } else {
      response.headers.chunkedTransferEncoding = true;
    }
    await response.addStream(reply);
    await response.close();
  }

  Future<void> _socket(HttpRequest request) async {
    final protocols = request.headers['sec-websocket-protocol']
        ?.expand((value) => value.split(','))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    final remote = await WebSocket.connect(
      _upstream.uri(request.uri, websocket: true).toString(),
      protocols: protocols,
      headers: {_upstream.header: _upstream.token},
      customClient: _upstream.client,
    );
    final local = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: protocols == null || protocols.isEmpty
          ? null
          : (_) => remote.protocol ?? protocols.first,
    );
    // 1005 ("no status") and 1006 ("abnormal") are reported, never sent.
    int? sendable(int? code) =>
        code == 1000 || (code != null && code >= 3000 && code < 5000)
        ? code
        : null;
    remote.listen(
      local.add,
      onDone: () => local.close(sendable(remote.closeCode)),
      onError: (_) => local.close(),
    );
    local.listen(
      remote.add,
      onDone: () => remote.close(sendable(local.closeCode)),
      onError: (_) => remote.close(),
    );
  }

  /// Stops serving and tells the computer the preview is closed.
  Future<void> close() async {
    await _server.close(force: true);
    _upstream.client.close(force: true);
    _onClose?.call();
  }
}

class _Upstream {
  _Upstream({
    required this.origin,
    required this.path,
    required this.header,
    required this.token,
    required this.client,
  });

  final Uri origin;
  final String path;
  final String header;
  final String token;
  final HttpClient client;

  /// [local] (the WebView's request) at the computer's preview path.
  Uri uri(Uri local, {required bool websocket}) {
    final scheme = origin.scheme == 'http'
        ? (websocket ? 'ws' : 'http')
        : (websocket ? 'wss' : 'https');
    return origin.replace(
      scheme: scheme,
      path: '$path${local.path.isEmpty ? '/' : local.path}',
      query: local.hasQuery ? local.query : null,
    );
  }
}
