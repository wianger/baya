import 'dart:async';

import 'package:app/data/agents/agent_notifier.dart';
import 'package:app/data/agents/agent_watch.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/acp_harness.dart';

class _Notifier implements AgentNotifier {
  LiveActivity? shown;
  int lives = 0;
  final alerts = <String, AgentAlert>{};
  int asks = 0;
  final _actions = StreamController<TappedAction>.broadcast();

  @override
  Future<void> live(LiveActivity? activity) async {
    shown = activity;
    lives++;
  }

  @override
  Future<void> alert(AgentAlert alert) async => alerts[alert.id] = alert;

  @override
  Future<void> cancel(String id) async => alerts.remove(id);

  @override
  Future<void> ask({bool settings = false}) async => asks++;

  @override
  Future<bool> allowed() async => true;

  void tap(NotificationAction action) =>
      _actions.add((payload: action.payload, text: null));

  void reply(NotificationReply reply, String text) =>
      _actions.add((payload: reply.payload, text: text));

  @override
  Stream<TappedAction> get actions => _actions.stream;

  @override
  Stream<SessionRef> get opened => const Stream.empty();

  @override
  Future<SessionRef?> takeLaunch() async => null;
}

void main() {
  late FakeHost host;
  late Hosts hosts;
  late Preferences prefs;
  late _Notifier notifier;
  late AgentWatch watch;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    prefs = Preferences();
    await prefs.load();
    host = FakeHost(
      sessions: [testSession(id: 'a', title: 'Fix the login redirect')],
    );
    hosts = testHosts(MemoryStorage([testPeer(name: 'studio')]), host);
    notifier = _Notifier();
    watch = AgentWatch(
      hosts,
      prefs,
      notifier,
      clock: () => DateTime.utc(2026, 11, 12, 9),
    )..start();
    await hosts.start();
    await settle();
  });

  tearDown(() {
    watch.dispose();
    hosts.dispose();
  });

  // As the host does: each turn that starts or ends is the latest activity.
  var tick = 0;
  void working(bool value) => host.push('_baya/session_changed', {
    'session': testSession(
      id: 'a',
      title: 'Fix the login redirect',
      working: value,
      updatedAt: DateTime.now().add(Duration(seconds: ++tick)),
    ).toJson(),
  });

  test('an agent at work shows live, and asks once to notify', () async {
    expect(notifier.shown, isNull);
    working(true);
    await settle();
    final live = notifier.shown!;
    expect(live.title, 'Fix the login redirect');
    expect(live.text, 'Claude Code · studio');
    expect(live.busy, isTrue);
    expect(live.since, DateTime.utc(2026, 11, 12, 9));
    expect(live.opens?.session, 'a');
    expect(notifier.asks, 1);

    working(false);
    await settle();
    expect(notifier.shown, isNull);
    // In front, the chat says so itself.
    expect(notifier.alerts, isEmpty);

    working(true);
    await settle();
    expect(notifier.asks, 1);
  });

  test('finishing while the app is away posts an alert', () async {
    working(true);
    await settle();
    watch.foreground = false;
    working(false);
    await settle();
    final done = notifier.alerts.values.single;
    expect(done.title, 'Fix the login redirect');
    expect(done.text, 'Claude Code finished · studio');

    // A new turn takes it back.
    working(true);
    await settle();
    expect(notifier.alerts, isEmpty);
  });

  test('a dropped connection is not a finished turn', () async {
    working(true);
    await settle();
    watch.foreground = false;
    host.socket!.drop();
    await settle();
    expect(notifier.alerts, isEmpty);
    expect(notifier.shown, isNull);
  });

  test('a permission question is answered from its notification', () async {
    working(true);
    await settle();
    watch.foreground = false;
    final answer = host.askPermission({
      'sessionId': 'a',
      'toolCall': {'toolCallId': 't1', 'title': 'npm test -- auth'},
      'options': [
        {'optionId': 'yes', 'name': 'Allow', 'kind': 'allow_once'},
        {'optionId': 'always', 'name': 'Always', 'kind': 'allow_always'},
        {'optionId': 'no', 'name': 'Reject', 'kind': 'reject_once'},
      ],
    });
    await settle();
    expect(notifier.shown!.chip, 'Approve');
    expect(notifier.shown!.busy, isFalse);
    final ask = notifier.alerts.values.single;
    expect(ask.title, 'Claude Code needs your approval');
    expect(ask.text, 'npm test -- auth\nFix the login redirect');
    expect([for (final a in ask.actions) a.label], ['Reject', 'Allow']);

    notifier.tap(ask.actions.last);
    expect(await answer, {
      'outcome': {'outcome': 'selected', 'optionId': 'yes'},
    });
    await settle();
    expect(notifier.alerts, isEmpty);
    expect(notifier.shown!.chip, isNull);
  });

  test('coming back withdraws the questions; the app shows them', () async {
    working(true);
    await settle();
    watch.foreground = false;
    // The question is still open when the test ends.
    host.askPermission({
      'sessionId': 'a',
      'toolCall': {'toolCallId': 't1', 'title': 'rm -rf build'},
      'options': [
        {'optionId': 'yes', 'name': 'Allow', 'kind': 'allow_once'},
      ],
    }).ignore();
    await settle();
    expect(notifier.alerts, hasLength(1));
    watch.foreground = true;
    expect(notifier.alerts, isEmpty);
  });

  test('Stop on the live notification interrupts the turn', () async {
    working(true);
    await settle();
    final stop = notifier.shown!.actions.single;
    expect(stop.label, 'Stop');
    notifier.tap(stop);
    await settle();
    final cancel = host.socket!.notifications.last;
    expect(cancel.method, 'session/cancel');
    expect(cancel.params, {'sessionId': 'a'});
  });

  test('turned off, nothing shows', () async {
    working(true);
    await settle();
    await prefs.setNotifyAgents(false);
    expect(notifier.shown, isNull);
    watch.foreground = false;
    working(false);
    await settle();
    expect(notifier.alerts, isEmpty);
  });

  test('a finished turn is answered from its notification', () async {
    working(true);
    await settle();
    watch.foreground = false;
    working(false);
    await settle();
    final done = notifier.alerts.values.single;
    expect(done.reply!.label, 'Reply');
    expect(done.reply!.hint, 'Reply to Claude Code…');

    notifier.reply(done.reply!, 'Now run the tests');
    await settle();
    final prompt = host.calls.lastWhere((c) => c.method == 'session/prompt');
    expect(prompt.params['sessionId'], 'a');
    expect(prompt.params['prompt'], [
      {'type': 'text', 'text': 'Now run the tests'},
    ]);
  });

  test('a reply with the computer away says it was not sent', () async {
    working(true);
    await settle();
    watch.foreground = false;
    working(false);
    await settle();
    final done = notifier.alerts.values.single;
    host.refuse = Exception('away');
    host.socket!.drop();
    await settle();
    notifier.reply(done.reply!, 'Now run the tests');
    await settle();
    expect(
      notifier.alerts.values.map((a) => a.title),
      contains("Your reply wasn't sent: the computer is offline"),
    );
  });

  test('reading the session in the app withdraws its notification', () async {
    working(true);
    await settle();
    watch.foreground = false;
    working(false);
    await settle();
    expect(notifier.alerts, hasLength(1));
    watch.foreground = true;
    prefs.markSeen(hosts.all.single.key, hosts.all.single.sessions.single);
    await settle();
    expect(notifier.alerts, isEmpty);
  });
}
