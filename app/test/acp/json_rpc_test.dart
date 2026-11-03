import 'dart:async';

import 'package:app/acp/json_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two peers wired back to back.
(JsonRpcPeer, JsonRpcPeer) pair({
  RequestHandler? onA,
  RequestHandler? onB,
  NotificationHandler? notifyA,
  NotificationHandler? notifyB,
}) {
  late JsonRpcPeer a;
  late JsonRpcPeer b;
  a = JsonRpcPeer(
    write: (m) => scheduleMicrotask(() => b.receive(m)),
    onRequest: onA ?? (method, _, _) async => throw RpcError(-32601, method),
    onNotification: notifyA ?? (_, _) {},
  );
  b = JsonRpcPeer(
    write: (m) => scheduleMicrotask(() => a.receive(m)),
    onRequest: onB ?? (method, _, _) async => throw RpcError(-32601, method),
    onNotification: notifyB ?? (_, _) {},
  );
  return (a, b);
}

void main() {
  test('requests and answers flow both ways', () async {
    final (phone, host) = pair(
      onA: (method, params, _) async => {'from': 'phone', 'method': method},
      onB: (method, params, _) async => {'echo': params['x']},
    );
    expect(await phone.call('ping', {'x': 1}), {'echo': 1});
    expect(await host.call('ask'), {'from': 'phone', 'method': 'ask'});
  });

  test('errors carry code, message and Baya reason', () async {
    final (phone, _) = pair(
      onB: (_, _, _) async =>
          throw const RpcError(-32000, 'not paired', {'reason': 'unpaired'}),
    );
    await expectLater(
      phone.call('initialize'),
      throwsA(
        isA<RpcError>()
            .having((e) => e.code, 'code', -32000)
            .having((e) => e.reason, 'reason', 'unpaired'),
      ),
    );
  });

  test('notifications reach the handler', () async {
    final seen = <String>[];
    final (phone, host) = pair(notifyB: (method, _) => seen.add(method));
    phone.notify('session/cancel', {'sessionId': 's'});
    await Future<void>.delayed(Duration.zero);
    expect(seen, ['session/cancel']);
    expect(host.isClosed, isFalse);
  });

  test('closing fails pending requests and later calls', () async {
    final never = Completer<Object?>();
    final (phone, _) = pair(onB: (_, _, _) => never.future);
    final pending = phone.call('slow');
    phone.close(const RpcClosed('gone'));
    await expectLater(pending, throwsA(isA<RpcClosed>()));
    await expectLater(phone.call('again'), throwsA(isA<RpcClosed>()));
  });

  test('the handler sees the request id', () async {
    Object? id;
    final (phone, _) = pair(
      onB: (_, _, requestId) async {
        id = requestId;
        return null;
      },
    );
    await phone.request('x');
    expect(id, 1);
  });
}
