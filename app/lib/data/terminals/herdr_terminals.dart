// The computer's herdr-core terminals: listed, started and attached through
// the host (`_baya/terminal_*`). An attached terminal's bytes arrive as data
// frames on a stream this phone picks; keys and sizes go back as
// notifications. A terminal outlives every connection: after a reconnect the
// stream attaches again and the computer paints the screen as it is now.
import 'dart:async';
import 'dart:math';

import 'package:app/acp/json_rpc.dart';
import 'package:app/data/hosts/host_connection.dart';
import 'package:app/data/transport/noise.dart';
import 'package:flutter/foundation.dart';

/// What terminals need of the connection to one computer.
abstract class TerminalLink {
  bool get isOnline;
  Future<Json> call(String method, Json params);
  void notify(String method, Json params);
  Stream<DataFrame> get data;

  /// `_baya/terminals_changed` and `_baya/terminal_closed`.
  Stream<({String method, Json params})> get news;

  /// Fires each time the connection (re)comes up.
  Stream<void> get onOnline;
}

class HostTerminalLink implements TerminalLink {
  HostTerminalLink(this.host);
  final HostConnection host;

  @override
  bool get isOnline => host.isOnline;
  @override
  Future<Json> call(String method, Json params) =>
      host.call(method, params, const Duration(seconds: 30));
  @override
  void notify(String method, Json params) => host.notify(method, params);
  @override
  Stream<DataFrame> get data => host.data;
  @override
  Stream<({String method, Json params})> get news => host.terminalNews;
  @override
  Stream<void> get onOnline => host.onOnline;
}

/// What a terminal's program said about itself (herdr's status protocol).
class TerminalStatus {
  const TerminalStatus({
    required this.state,
    this.app,
    this.kind,
    this.message,
    this.progress,
  });

  factory TerminalStatus.fromJson(Map<String, dynamic> json) => TerminalStatus(
    state: json['state'] as String? ?? '',
    app: _text(json['app']),
    kind: _text(json['kind']),
    message: _text(json['msg']),
    progress: json['progress'] as int?,
  );

  /// idle, working, done, blocked or error.
  final String state;
  final String? app;

  /// permission, question or auth, when blocked.
  final String? kind;
  final String? message;
  final int? progress;

  bool get blocked => state == 'blocked';
  bool get working => state == 'working';
}

class HerdrTerminal {
  const HerdrTerminal({
    required this.address,
    required this.argv,
    required this.cwd,
    required this.live,
    this.name,
    this.title = '',
    this.status,
    this.program,
    this.programCwd,
    this.created,
    this.exitCode,
    this.reason,
    this.labels = const {},
    this.cols,
    this.rows,
  });

  factory HerdrTerminal.fromJson(Map<String, dynamic> json) {
    final foreground = json['foreground'];
    final status = json['status'];
    final created = json['created_ms'];
    return HerdrTerminal(
      address: json['address'] as String,
      name: _text(json['name']),
      argv: [
        for (final part in json['argv'] as List? ?? const [])
          if (part is String) part,
      ],
      cwd: json['cwd'] as String? ?? '',
      live: json['state'] == 'live',
      title: (json['title'] as String? ?? '').trim(),
      status: status is Map
          ? TerminalStatus.fromJson(status.cast<String, dynamic>())
          : null,
      program: foreground is Map ? _text(foreground['name']) : null,
      programCwd: foreground is Map ? _text(foreground['cwd']) : null,
      created: created is int
          ? DateTime.fromMillisecondsSinceEpoch(created)
          : null,
      exitCode: json['exit_code'] as int?,
      reason: _text(json['reason']),
      labels: {
        for (final MapEntry(:key, :value)
            in (json['labels'] as Map? ?? const {}).entries)
          if (key is String && value is String) key: value,
      },
      cols: json['cols'] as int?,
      rows: json['rows'] as int?,
    );
  }

  /// Its size on the computer, when known.
  final int? cols;
  final int? rows;

  /// `t7`, or `box/t7` on a machine herdr added.
  final String address;
  final String? name;
  final List<String> argv;
  final String cwd;
  final bool live;
  final String title;
  final TerminalStatus? status;

  /// What runs in it now (`claude`, `vim`, `fish`) and where.
  final String? program;
  final String? programCwd;
  final DateTime? created;
  final int? exitCode;
  final String? reason;

  /// hc's labels; Baya marks a session's own terminal `baya.session`.
  final Map<String, String> labels;

  /// Its program asks for the user: a permission, a question, a sign-in.
  bool get needsYou => live && (status?.blocked ?? false);

  /// The agent or program in it, in a word.
  String get app =>
      status?.app ??
      program ??
      (argv.isEmpty ? 'shell' : argv.first.split(RegExp(r'[/\\]')).last);

  /// Its folder now, else where it started.
  String get folder => programCwd ?? cwd;

  String get label => name ?? (title.isNotEmpty ? title : app);
}

class TerminalList {
  const TerminalList({required this.available, required this.terminals});

  /// Whether herdr-core is installed on the computer.
  final bool available;

  /// Waiting for the user first, then live by age, then finished.
  final List<HerdrTerminal> terminals;
}

/// A terminal attached to this phone. Survives the connection: it attaches
/// again once the computer is back, and [resets] says to start a fresh
/// screen for the paint that follows.
class TerminalStream {
  TerminalStream._(this._link, this.address);

  final TerminalLink _link;
  final String address;
  int _stream = 0;
  int _received = 0;
  int _cols = 80;
  int _rows = 24;
  bool _closed = false;
  bool _attached = false;

  /// Watching it as it is: the computer keeps its size, told in [sizes].
  bool _observe = false;
  StreamSubscription<DataFrame>? _frames;
  StreamSubscription<({String method, Json params})>? _news;
  StreamSubscription<void>? _online;

  // Held until the page listens: the first paint (and its size) can come
  // in before the attach's answer does, and must not be lost.
  final _bytes = StreamController<Uint8List>();
  final _resets = StreamController<void>();
  final _sizes = StreamController<(int, int)>();
  final _ended = Completer<String>();

  /// The program's output, starting with a paint of the screen.
  Stream<Uint8List> get bytes => _bytes.stream;

  /// A fresh paint follows: clear the screen and scrollback first.
  Stream<void> get resets => _resets.stream;

  /// An observed terminal's size (columns, rows) as the computer changes
  /// it, each before the paint at that size.
  Stream<(int, int)> get sizes => _sizes.stream;

  /// Completes with the reason (`exited`, `killed` …) once the program ended
  /// or the terminal went away on the computer.
  Future<String> get ended => _ended.future;

  static final _random = Random.secure();

  Future<HerdrTerminal> _attach({required bool resumed}) async {
    final stream = _random.nextInt(0x7fffffff) + 1;
    _stream = stream;
    _received = 0;
    final result = await _link.call('_baya/terminal_attach', {
      'terminal': address,
      'stream': stream,
      'cols': _cols,
      'rows': _rows,
      'resumed': resumed,
      if (_observe) 'observe': true,
    });
    _attached = true;
    return HerdrTerminal.fromJson(
      (result['terminal'] as Map).cast<String, dynamic>(),
    );
  }

  void _start() {
    _frames = _link.data.listen((frame) {
      if (frame.stream != _stream || frame.offset != _received) return;
      _received += frame.bytes.length;
      if (!_bytes.isClosed) _bytes.add(frame.bytes);
    });
    _news = _link.news.listen((event) {
      if (event.method == '_baya/terminal_size' &&
          event.params['stream'] == _stream) {
        final cols = event.params['cols'];
        final rows = event.params['rows'];
        if (cols is int && rows is int && !_sizes.isClosed) {
          _sizes.add((cols, rows));
        }
        return;
      }
      if (event.method != '_baya/terminal_closed' ||
          event.params['stream'] != _stream) {
        return;
      }
      _attached = false;
      final reason = event.params['reason'] as String? ?? 'closed';
      // The computer's link to herdr dropped: attach again shortly.
      if (reason == 'core_lost' && !_closed) {
        Timer(const Duration(seconds: 2), _reattach);
        return;
      }
      if (!_ended.isCompleted) _ended.complete(reason);
    });
    _online = _link.onOnline.listen((_) => _reattach());
  }

  Future<void> _reattach() async {
    if (_closed || _ended.isCompleted || !_link.isOnline) return;
    _attached = false;
    if (!_resets.isClosed) _resets.add(null);
    try {
      await _attach(resumed: true);
    } catch (error) {
      // Gone from the computer meanwhile.
      if (error is RpcError && !_ended.isCompleted) {
        _ended.complete('removed');
      }
    }
  }

  /// Keys as the terminal encodes them.
  void input(String data) {
    if (!_attached || data.isEmpty) return;
    _link.notify('_baya/terminal_input', {'stream': _stream, 'data': data});
  }

  void resize(int cols, int rows) {
    if (cols < 1 || rows < 1 || (cols == _cols && rows == _rows)) return;
    _cols = cols;
    _rows = rows;
    if (!_attached) return;
    _link.notify('_baya/terminal_resize', {
      'stream': _stream,
      'cols': cols,
      'rows': rows,
    });
  }

  /// Stops watching; the terminal keeps running on the computer.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _frames?.cancel();
    await _news?.cancel();
    await _online?.cancel();
    if (_attached && _link.isOnline) {
      unawaited(
        _link
            .call('_baya/terminal_detach', {'stream': _stream})
            .then((_) {}, onError: (_) {}),
      );
    }
    await _bytes.close();
    await _resets.close();
    await _sizes.close();
  }
}

class TerminalsRepository {
  TerminalsRepository(this._link);
  final TerminalLink _link;

  /// Some terminal started, changed status, ended or went away.
  Stream<void> get changes => _link.news
      .where((event) => event.method == '_baya/terminals_changed')
      .map((_) {});

  Future<TerminalList> list() async {
    final result = await _link.call('_baya/terminal_list', const {});
    final terminals = [
      for (final item in result['terminals'] as List? ?? const [])
        if (item is Map) HerdrTerminal.fromJson(item.cast<String, dynamic>()),
    ];
    int rank(HerdrTerminal t) => t.needsYou ? 0 : (t.live ? 1 : 2);
    terminals.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return (b.created ?? DateTime(0)).compareTo(a.created ?? DateTime(0));
    });
    return TerminalList(
      available: result['available'] != false,
      terminals: terminals,
    );
  }

  /// The computer's shell in [cwd], or a [line] such as `claude`; [session]
  /// makes it that session's own.
  Future<HerdrTerminal> run({
    String? cwd,
    String? line,
    String? session,
    int? cols,
    int? rows,
  }) async {
    final result = await _link.call('_baya/terminal_run', {
      'cwd': ?cwd,
      'session': ?session,
      if (line != null && line.trim().isNotEmpty) 'line': line.trim(),
      'cols': ?cols,
      'rows': ?rows,
    });
    return HerdrTerminal.fromJson(result.cast<String, dynamic>());
  }

  /// [sessionId]'s terminal in herdr, as the computer finds it: the one
  /// kept for it, one where its agent already runs in its folder, its
  /// agent's own TUI resumed on the conversation, or else a shell there.
  /// Null when herdr-core is not on the computer.
  Future<HerdrTerminal?> forSession(String sessionId) async {
    final result = await _link.call('_baya/terminal_session', {
      'sessionId': sessionId,
    });
    final terminal = result['terminal'];
    if (result['available'] == false || terminal is! Map) return null;
    return HerdrTerminal.fromJson(terminal.cast<String, dynamic>());
  }

  /// Starts watching [address] at [cols]×[rows]; [observe] watches it at
  /// its own size instead, which the computer keeps.
  Future<(TerminalStream, HerdrTerminal)> attach(
    String address, {
    required int cols,
    required int rows,
    bool observe = false,
  }) async {
    final stream = TerminalStream._(_link, address)
      .._cols = cols
      .._rows = rows
      .._observe = observe
      .._start();
    try {
      return (stream, await stream._attach(resumed: false));
    } catch (_) {
      await stream.close();
      rethrow;
    }
  }

  /// [address]'s screen and up to [lines] of history above it, as text:
  /// further back than an attach sends.
  Future<String> read(String address, {int lines = 10000}) async {
    final result = await _link.call('_baya/terminal_read', {
      'terminal': address,
      'lines': lines,
    });
    return result['text'] as String? ?? '';
  }

  Future<void> kill(String address) =>
      _link.call('_baya/terminal_kill', {'terminal': address});

  Future<void> remove(String address) =>
      _link.call('_baya/terminal_remove', {'terminal': address});
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// Whether [host] is connected, as a listenable for terminal pages.
class HostOnline extends ChangeNotifier implements ValueListenable<bool> {
  HostOnline(this.host) {
    host.addListener(_changed);
  }

  final HostConnection host;
  late bool _last = host.isOnline;

  @override
  bool get value => host.isOnline;

  void _changed() {
    if (host.isOnline == _last) return;
    _last = host.isOnline;
    notifyListeners();
  }

  @override
  void dispose() {
    host.removeListener(_changed);
    super.dispose();
  }
}
