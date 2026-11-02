import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class Reply {
  final int status;
  final String body;
  const Reply(this.status, this.body);
}

/// Canned HTTP replies by `METHOD /path`, recording what was sent.
class StubHttp {
  final _replies = <String, Reply>{};
  final _sequences = <String, List<Reply>>{};
  http.Request? lastRequest;
  String? lastBody;
  int getCount = 0;
  int postCount = 0;

  void on(String method, String path, Reply reply) =>
      _replies['$method $path'] = reply;

  /// Successive calls get successive replies; the last one repeats.
  void onSequence(String method, String path, List<Reply> replies) =>
      _sequences['$method $path'] = List.of(replies);

  late final http.Client client = MockClient((request) async {
    lastRequest = request;
    lastBody = request.body.isEmpty ? null : request.body;
    if (request.method == 'GET') getCount++;
    if (request.method == 'POST') postCount++;
    final key = '${request.method} ${request.url.path}';
    final sequence = _sequences[key];
    final reply = sequence != null
        ? (sequence.length > 1 ? sequence.removeAt(0) : sequence.single)
        : _replies[key];
    if (reply == null) {
      throw StateError('No stub for $key — registered: ${_replies.keys}');
    }
    return http.Response(
      reply.body,
      reply.status,
      headers: {'content-type': 'application/json'},
    );
  });
}
