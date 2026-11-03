// Folds ACP `session/update`s into the rows the chat shows. Pure: no I/O.

import 'package:app/acp/acp.dart';
import 'package:app/domain/session_state.dart';

class Transcript {
  final _rows = <ChatMessage>[];

  /// Prompts sent from this phone that the computer has not started yet.
  final _pending = <UserMsg>[];

  /// Terminal output by terminal id, attached to the tool calls showing it.
  final _terminals = <String, TerminalSnapshot>{};
  int _sequence = 0;

  /// Confirmed rows, then this phone's pending prompts.
  List<ChatMessage> get messages => [..._rows, ..._pending];

  bool get isEmpty => _rows.isEmpty && _pending.isEmpty;

  void clear() {
    _rows.clear();
    _terminals.clear();
    _sequence = 0;
  }

  /// Shows a prompt right away; its echo from the computer replaces it.
  void addPending(UserMsg message) => _pending.add(message);

  void dropPending(String id) => _pending.removeWhere((m) => m.id == id);

  /// Ends a turn: nothing is still being written.
  void settle() {
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row is ThinkingMsg && !row.complete) {
        _rows[i] = ThinkingMsg(id: row.id, text: row.text);
      }
    }
  }

  /// A terminal's latest output, shown on the tool call that runs it.
  void terminal(TerminalSnapshot snapshot) {
    _terminals[snapshot.terminalId] = snapshot;
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row is ToolEvent && row.terminalIds.contains(snapshot.terminalId)) {
        _rows[i] = row.withTerminal(snapshot);
      }
    }
  }

  ToolEvent _withKnownTerminal(ToolEvent tool) {
    for (final id in tool.terminalIds) {
      final snapshot = _terminals[id];
      if (snapshot != null) return tool.withTerminal(snapshot);
    }
    return tool;
  }

  /// Marks the tool calls a permission question is waiting on.
  void markAwaiting(Set<String> toolCallIds) {
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row is ToolEvent) {
        _rows[i] = row.withApproval(toolCallIds.contains(row.toolCallId));
      }
    }
  }

  void apply(SessionUpdate update) {
    if (update is! MessageChunk || update.role != ChunkRole.thought) {
      _completeThinking();
    }
    switch (update) {
      case MessageChunk(
        :final role,
        :final content,
        :final messageId,
        :final startup,
      ):
        switch (role) {
          case ChunkRole.user:
            _userChunk(content, messageId);
          case ChunkRole.agent:
            if (content is ImageContent) {
              _rows.add(
                AgentImageMsg(
                  id: _nextId('image'),
                  image: MessageImage(
                    data: content.data,
                    mime: content.mimeType,
                  ),
                ),
              );
            } else {
              _agentChunk(content.displayText, messageId, startup: startup);
            }
          case ChunkRole.thought:
            _thoughtChunk(content.displayText, messageId);
        }
      case ToolCallUpdate(:final patch):
        final index = _rows.lastIndexWhere(
          (row) => row is ToolEvent && row.toolCallId == patch.id,
        );
        if (index >= 0) {
          _rows[index] = _withKnownTerminal(
            (_rows[index] as ToolEvent).apply(patch),
          );
        } else {
          _rows.add(
            _withKnownTerminal(
              ToolEvent(
                id: 'tool-${patch.id}',
                toolCallId: patch.id,
              ).apply(patch),
            ),
          );
        }
      case PlanUpdate(:final entries):
        final index = _indexInTurn((row) => row is PlanMsg);
        final plan = PlanMsg(
          id: index >= 0 ? _rows[index].id : _nextId('plan'),
          entries: entries,
        );
        if (index >= 0) {
          _rows[index] = plan;
        } else {
          _rows.add(plan);
        }
      case NoticeUpdate(:final severity, :final title, :final authAgent):
        _rows.add(
          NoticeMsg(
            id: _nextId('notice'),
            severity: severity,
            text: title,
            authAgent: authAgent,
          ),
        );
      case CompactionUpdate(:final id, :final status, :final summary):
        final index = _compaction(id);
        final previous = index >= 0 ? _rows[index] as CompactionMsg : null;
        final row = CompactionMsg(
          id: 'compaction-$id',
          summary: summary ?? previous?.summary ?? '',
          done: status != 'in_progress',
        );
        if (index >= 0) {
          _rows[index] = row;
        } else {
          _rows.add(row);
        }
      case CompactionSummaryChunk(:final id, :final text):
        final index = _compaction(id);
        if (index >= 0) {
          final previous = _rows[index] as CompactionMsg;
          _rows[index] = CompactionMsg(
            id: previous.id,
            summary: previous.summary + text,
            done: previous.done,
          );
        } else {
          _rows.add(CompactionMsg(id: 'compaction-$id', summary: text));
        }
      case CommandsUpdate() ||
          ModeUpdate() ||
          ConfigUpdate() ||
          SessionInfoChanged() ||
          UsageUpdate() ||
          UnknownUpdate():
        break;
    }
  }

  void _userChunk(ContentBlock content, String? messageId) {
    final last = _rows.lastOrNull;
    final image = content is ImageContent
        ? MessageImage(data: content.data, mime: content.mimeType)
        : null;
    final text = content.displayText;
    if (last is UserMsg && messageId != null && last.id == messageId) {
      _rows[_rows.length - 1] = last.copyWith(
        text: last.text + text,
        image: image,
      );
      return;
    }
    final id = messageId ?? _nextId('user');
    final sent = _pending.where((m) => m.id == id).firstOrNull;
    _pending.removeWhere((m) => m.id == id);
    _rows.add(
      UserMsg(
        id: id,
        text: text,
        image: image ?? (text.isEmpty ? sent?.image : null),
      ),
    );
  }

  void _agentChunk(String text, String? messageId, {bool startup = false}) {
    final last = _rows.lastOrNull;
    if (last is AssistantMsg &&
        last.startup == startup &&
        (messageId == null || last.id == messageId)) {
      _rows[_rows.length - 1] = AssistantMsg(
        id: last.id,
        text: last.text + text,
        startup: startup,
      );
      return;
    }
    if (text.isEmpty) return;
    _rows.add(
      AssistantMsg(
        id: messageId ?? _nextId('agent'),
        text: text,
        startup: startup,
      ),
    );
  }

  void _thoughtChunk(String text, String? messageId) {
    final last = _rows.lastOrNull;
    if (last is ThinkingMsg && (messageId == null || last.id == messageId)) {
      _rows[_rows.length - 1] = ThinkingMsg(
        id: last.id,
        text: last.text + text,
        complete: false,
      );
      return;
    }
    if (text.isEmpty) return;
    _rows.add(
      ThinkingMsg(
        id: messageId ?? _nextId('thought'),
        text: text,
        complete: false,
      ),
    );
  }

  void _completeThinking() {
    final last = _rows.lastOrNull;
    if (last is ThinkingMsg && !last.complete) {
      _rows[_rows.length - 1] = ThinkingMsg(id: last.id, text: last.text);
    }
  }

  /// Index of the last row matching [test] since the latest user message.
  int _indexInTurn(bool Function(ChatMessage row) test) {
    for (var i = _rows.length - 1; i >= 0; i--) {
      final row = _rows[i];
      if (row is UserMsg) return -1;
      if (test(row)) return i;
    }
    return -1;
  }

  int _compaction(String id) => _rows.lastIndexWhere(
    (row) => row is CompactionMsg && row.id == 'compaction-$id',
  );

  String _nextId(String kind) => '$kind-${_sequence++}';
}
