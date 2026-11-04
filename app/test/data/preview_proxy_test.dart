import 'dart:convert';
import 'dart:io';

import 'package:app/data/preview/preview_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the host's preview route: checks the token and the path
/// prefix, answers plain requests and echoes WebSocket messages.
Future<HttpServer> _host() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.headers.value('x-baya-preview') != 'secret' ||
        !request.uri.path.startsWith('/baya-pair/wsl/preview/')) {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    final path = request.uri.path.substring('/baya-pair/wsl/preview'.length);
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((message) => socket.add('echo $path $message'));
      return;
    }
    final body = await utf8.decodeStream(request);
    request.response.headers
      ..add('set-cookie', 'sid=1; Path=/; Secure; Domain=box.ts.net; HttpOnly')
      ..contentType = ContentType.text;
    request.response.write(
      '${request.method} $path?${request.uri.query} '
      'ua=${request.headers.value('user-agent')} body=$body',
    );
    await request.response.close();
  });
  return server;
}

void main() {
  test(
    'forwards requests with the token, at the root of its own origin',
    () async {
      final host = await _host();
      var closed = false;
      final proxy = await PreviewProxy.serve(
        port: 5173,
        origin: Uri.parse('http://127.0.0.1:${host.port}/baya-pair/wsl/direct'),
        path: '/baya-pair/wsl/preview',
        header: 'x-baya-preview',
        token: 'secret',
        onClose: () => closed = true,
      );
      final client = HttpClient();
      final request = await client.postUrl(proxy.url('/api/items?page=2'));
      request.headers.set('user-agent', 'WebView');
      request.write('hello');
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(
        await utf8.decodeStream(response),
        'POST /api/items?page=2 ua=WebView body=hello',
      );
      expect(response.headers['set-cookie'], ['sid=1; Path=/; HttpOnly']);

      final socket = await WebSocket.connect(
        proxy.url('/@vite/hmr').replace(scheme: 'ws').toString(),
      );
      socket.add('ping');
      expect(await socket.first, 'echo /@vite/hmr ping');
      await socket.close();

      client.close();
      await proxy.close();
      expect(closed, isTrue);
      await host.close(force: true);
    },
  );

  test('tells localhost links apart', () {
    expect(localPort(Uri.parse('http://localhost:5173/about')), 5173);
    expect(localPort(Uri.parse('http://127.0.0.1:8080')), 8080);
    expect(localPort(Uri.parse('http://localhost/')), 80);
    expect(localPort(Uri.parse('https://example.com:5173')), isNull);
    expect(localPort(Uri.parse('mailto:me@localhost')), isNull);
  });

  test('keeps cookies usable on the loopback origin', () {
    expect(
      loopbackCookie('a=1; Secure; Domain=x.ts.net; SameSite=None; Path=/'),
      'a=1; Path=/',
    );
  });
}
