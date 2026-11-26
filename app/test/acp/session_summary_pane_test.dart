import 'package:app/acp/acp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a session in a herdr pane says so, and when it waits for an answer',
    () {
      final waiting = SessionSummary.fromJson({
        'sessionId': 'herdr-w1-p2',
        'cwd': '/w',
        'title': 'Fix it',
        '_meta': {
          'baya': {
            'agent': 'claude',
            'agentName': 'Claude Code',
            'herdr': {'pane': 'w1:p2', 'status': 'blocked'},
          },
        },
      });
      expect(waiting.inPane, isTrue);
      expect(waiting.waitingForAnswer, isTrue);
      expect(SessionSummary.fromJson(waiting.toJson()).paneStatus, 'blocked');

      final own = SessionSummary.fromJson({'sessionId': 's', 'cwd': '/w'});
      expect(own.inPane, isFalse);
      expect(own.waitingForAnswer, isFalse);
    },
  );
}
