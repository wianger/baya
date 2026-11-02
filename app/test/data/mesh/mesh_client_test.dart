import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/mesh/mesh_client.dart';
import 'package:app/data/mesh/mesh_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/stub_http.dart';

MeshClient _makeClient(StubHttp stub) => MeshClient(
  baseUrlProvider: () => 'https://relay.example',
  client: stub.client,
);

void main() {
  group('MeshClient.ownerPkHash', () {
    test('produces 64-char lowercase hex SHA-256', () async {
      final pk = Uint8List.fromList(List.filled(32, 0));
      final hex = await MeshClient.ownerPkHash(pk);
      expect(hex.length, 64);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(hex), isTrue);
      // sha256(zeroes32) → known value
      expect(
        hex,
        '66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925',
      );
    });
  });

  group('MeshClient.fetch', () {
    late StubHttp adapter;
    late MeshClient client;

    setUp(() {
      adapter = StubHttp();
      client = _makeClient(adapter);
    });

    test('200 OK → MeshFetchOk with parsed envelope', () async {
      adapter.on(
        'GET',
        '/mesh/abc',
        Reply(
          200,
          jsonEncode({
            'blob': base64.encode(utf8.encode('{"version":1}')),
            'sig': base64.encode(List.filled(64, 1)),
            'version': 7,
            'updated_at': 1700000000000,
          }),
        ),
      );
      final result = await client.fetch('abc');
      expect(result, isA<MeshFetchOk>());
      final ok = result as MeshFetchOk;
      expect(ok.version, 7);
      expect(ok.updatedAt, 1700000000000);
      expect(ok.envelope.sig.length, 64);
    });

    test('304 → MeshFetchNotModified', () async {
      adapter.on('GET', '/mesh/abc', const Reply(304, ''));
      expect(await client.fetch('abc', since: 5), isA<MeshFetchNotModified>());
    });

    test('404 → MeshFetchNotFound', () async {
      adapter.on('GET', '/mesh/abc', const Reply(404, ''));
      expect(await client.fetch('abc'), isA<MeshFetchNotFound>());
    });

    test('500 → MeshFetchFailure with status in message', () async {
      adapter.on('GET', '/mesh/abc', Reply(500, jsonEncode({'error': 'oops'})));
      final r = await client.fetch('abc');
      expect(r, isA<MeshFetchFailure>());
      expect((r as MeshFetchFailure).reason, contains('500'));
    });

    test('since query parameter is forwarded', () async {
      adapter.on('GET', '/mesh/abc', const Reply(304, ''));
      await client.fetch('abc', since: 12);
      expect(adapter.lastRequest?.url.queryParameters['since'], '12');
    });

    test('omits since when null', () async {
      adapter.on('GET', '/mesh/abc', const Reply(404, ''));
      await client.fetch('abc');
      expect(
        adapter.lastRequest?.url.queryParameters.containsKey('since'),
        isFalse,
      );
    });
  });

  group('MeshClient.publish', () {
    late StubHttp adapter;
    late MeshClient client;
    final envelope = MeshEnvelope(
      blob: Uint8List.fromList(utf8.encode('{"version":1}')),
      sig: Uint8List.fromList(List.filled(64, 9)),
    );

    setUp(() {
      adapter = StubHttp();
      client = _makeClient(adapter);
    });

    test('200 → MeshPublishOk', () async {
      adapter.on(
        'POST',
        '/mesh/abc',
        Reply(200, jsonEncode({'version': 8, 'updated_at': 1700000000000})),
      );
      final r = await client.publish('abc', envelope);
      expect(r, isA<MeshPublishOk>());
      expect((r as MeshPublishOk).version, 8);
    });

    test('400 → MeshPublishBadRequest with extracted message', () async {
      adapter.on(
        'POST',
        '/mesh/abc',
        Reply(400, jsonEncode({'message': 'version must be int'})),
      );
      final r = await client.publish('abc', envelope);
      expect(r, isA<MeshPublishBadRequest>());
      expect((r as MeshPublishBadRequest).message, 'version must be int');
    });

    test('403 → MeshPublishForbidden', () async {
      adapter.on('POST', '/mesh/abc', const Reply(403, ''));
      expect(
        await client.publish('abc', envelope),
        isA<MeshPublishForbidden>(),
      );
    });

    test('409 → MeshPublishConflict', () async {
      adapter.on('POST', '/mesh/abc', const Reply(409, ''));
      expect(await client.publish('abc', envelope), isA<MeshPublishConflict>());
    });

    test('413 → MeshPublishTooLarge', () async {
      adapter.on('POST', '/mesh/abc', const Reply(413, ''));
      expect(await client.publish('abc', envelope), isA<MeshPublishTooLarge>());
    });

    test('500 → MeshPublishFailure', () async {
      adapter.on('POST', '/mesh/abc', const Reply(500, ''));
      final r = await client.publish('abc', envelope);
      expect(r, isA<MeshPublishFailure>());
    });

    test('request body contains the envelope JSON', () async {
      adapter.on(
        'POST',
        '/mesh/abc',
        Reply(200, jsonEncode({'version': 1, 'updated_at': 0})),
      );
      await client.publish('abc', envelope);
      expect(adapter.lastBody, isNotNull);
      final parsed = jsonDecode(adapter.lastBody!) as Map<String, Object?>;
      expect(parsed['blob'], base64.encode(envelope.blob));
      expect(parsed['sig'], base64.encode(envelope.sig));
    });
  });
}
