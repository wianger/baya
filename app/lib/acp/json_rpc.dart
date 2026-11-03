// A transport-agnostic JSON-RPC 2.0 peer. ACP is symmetric: the phone sends
// requests to the computer and the computer sends requests (permission
// questions) back, so one class serves both directions.

import 'dart:async';

typedef Json = Map<String, dynamic>;

class RpcError implements Exception {
  final int code;
  final String message;
  final Object? data;
  const RpcError(this.code, this.message, [this.data]);

  /// `data.reason` from Baya's errors (`unpaired`, `token_expired`, …).
  String? get reason => data is Map ? (data as Map)['reason'] as String? : null;

  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const notPaired = -32000;
  static const notFound = -32002;

  Json toJson() => {
    'code': code,
    'message': message,
    if (data != null) 'data': data,
  };

  @override
  String toString() => message;
}

/// The connection went away before an answer arrived.
class RpcClosed implements Exception {
  final String reason;
  const RpcClosed(this.reason);

  @override
  String toString() => reason;
}

/// [id] lets the handler match a later `$/cancel_request` from the peer.
typedef RequestHandler = Future<Object?> Function(
  String method,
  Json params,
  Object id,
);
typedef NotificationHandler = void Function(String method, Json params);

class JsonRpcPeer {
  JsonRpcPeer({
    required this._write,
    required this._onRequest,
    required this._onNotification,
  });

  final void Function(Json message) _write;
  final RequestHandler _onRequest;
  final NotificationHandler _onNotification;
  final _pending = <Object, Completer<Object?>>{};
  int _sequence = 0;
  Object? _closed;

  bool get isClosed => _closed != null;

  Future<Object?> request(String method, [Json params = const {}]) {
    if (_closed != null) return Future.error(_closed!);
    final id = ++_sequence;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future;
  }

  /// [request] for a JSON object result.
  Future<Json> call(String method, [Json params = const {}]) async {
    final result = await request(method, params);
    return result is Map ? result.cast<String, dynamic>() : const {};
  }

  void notify(String method, [Json params = const {}]) {
    if (_closed != null) return;
    _write({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  void receive(Object? message) {
    if (message is! Map) return;
    final json = message.cast<String, dynamic>();
    final id = json['id'];
    final method = json['method'];
    if (method is String) {
      final raw = json['params'];
      final params = raw is Map
          ? raw.cast<String, dynamic>()
          : <String, dynamic>{};
      if (id == null) {
        _onNotification(method, params);
        return;
      }
      _answer(id as Object, method, params);
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null) return;
    final error = json['error'];
    if (error is Map) {
      completer.completeError(
        RpcError(
          (error['code'] as num?)?.toInt() ?? -32603,
          (error['message'] as String?) ?? 'Request failed.',
          error['data'],
        ),
      );
    } else {
      completer.complete(json['result']);
    }
  }

  Future<void> _answer(Object id, String method, Json params) async {
    try {
      final result = await _onRequest(method, params, id);
      if (_closed == null) {
        _write({'jsonrpc': '2.0', 'id': id, 'result': result});
      }
    } catch (error) {
      if (_closed != null) return;
      final rpc = error is RpcError ? error : RpcError(-32603, '$error');
      _write({'jsonrpc': '2.0', 'id': id, 'error': rpc.toJson()});
    }
  }

  /// Fails every outstanding request; later calls fail immediately.
  void close(Object reason) {
    if (_closed != null) return;
    _closed = reason;
    for (final completer in _pending.values) {
      completer.completeError(reason);
    }
    _pending.clear();
  }
}
