// A conversation as the chat renders it, folded from ACP `session/update`s.
// Lives in domain/ → no Flutter, no network, no storage.

import 'package:app/acp/acp.dart';

sealed class ChatMessage {
  final String id;
  const ChatMessage({required this.id});
}

/// `pending` = sent, not yet started by the agent (it may be queued behind a
/// running turn); `confirmed` = the computer recorded it.
enum UserMsgStatus { pending, confirmed }

/// An image attached to a user message, base64 without a data-URI prefix.
class MessageImage {
  final String data;
  final String mime;

  const MessageImage({required this.data, required this.mime});

  @override
  bool operator ==(Object other) =>
      other is MessageImage && other.data == data && other.mime == mime;

  @override
  int get hashCode => Object.hash(data, mime);
}

class UserMsg extends ChatMessage {
  final String text;
  final UserMsgStatus status;
  final MessageImage? image;

  const UserMsg({
    required super.id,
    required this.text,
    this.status = UserMsgStatus.confirmed,
    this.image,
  });

  UserMsg copyWith({
    String? text,
    UserMsgStatus? status,
    MessageImage? image,
  }) => UserMsg(
    id: id,
    text: text ?? this.text,
    status: status ?? this.status,
    image: image ?? this.image,
  );

  @override
  bool operator ==(Object other) =>
      other is UserMsg &&
      other.id == id &&
      other.text == text &&
      other.status == status &&
      other.image == image;

  @override
  int get hashCode => Object.hash(id, text, status, image);
}

class AssistantMsg extends ChatMessage {
  final String text;

  /// Startup chatter (version, loaded skills), not a reply.
  final bool startup;
  const AssistantMsg({
    required super.id,
    required this.text,
    this.startup = false,
  });

  @override
  bool operator ==(Object other) =>
      other is AssistantMsg &&
      other.id == id &&
      other.text == text &&
      other.startup == startup;

  @override
  int get hashCode => Object.hash(id, text, startup);
}

/// The agent's visible reasoning, separate from its reply.
class ThinkingMsg extends ChatMessage {
  final String text;
  final bool complete;
  const ThinkingMsg({required super.id, this.text = '', this.complete = true});

  @override
  bool operator ==(Object other) =>
      other is ThinkingMsg &&
      other.id == id &&
      other.text == text &&
      other.complete == complete;

  @override
  int get hashCode => Object.hash(id, text, complete);
}

enum ToolEventStatus { pending, running, completed, failed }

/// One tool call, in its latest state.
class ToolEvent extends ChatMessage {
  final String toolCallId;
  final String title;
  final ToolKind kind;
  final ToolEventStatus status;
  final List<ToolCallContent> content;
  final List<ToolLocation> locations;
  final Object? rawInput;
  final Object? rawOutput;

  /// A permission question for this call is open.
  final bool awaitingApproval;

  /// The live terminal this call runs, when it runs one.
  final TerminalSnapshot? terminal;

  const ToolEvent({
    required super.id,
    required this.toolCallId,
    this.title = '',
    this.kind = ToolKind.other,
    this.status = ToolEventStatus.pending,
    this.content = const [],
    this.locations = const [],
    this.rawInput,
    this.rawOutput,
    this.awaitingApproval = false,
    this.terminal,
  });

  /// Terminal ids this call shows.
  Iterable<String> get terminalIds =>
      content.whereType<ToolCallTerminal>().map((item) => item.terminalId);

  /// Applies an ACP patch: absent fields keep their value.
  ToolEvent apply(ToolCallPatch patch) => ToolEvent(
    id: id,
    toolCallId: toolCallId,
    title: patch.title ?? title,
    kind: patch.kind ?? kind,
    status: patch.status == null ? status : statusOf(patch.status!),
    content: patch.content ?? content,
    locations: patch.locations ?? locations,
    rawInput: patch.rawInput ?? rawInput,
    rawOutput: patch.rawOutput ?? rawOutput,
    awaitingApproval: awaitingApproval,
    terminal: terminal,
  );

  ToolEvent withTerminal(TerminalSnapshot snapshot) => ToolEvent(
    id: id,
    toolCallId: toolCallId,
    title: title,
    kind: kind,
    status: status,
    content: content,
    locations: locations,
    rawInput: rawInput,
    rawOutput: rawOutput,
    awaitingApproval: awaitingApproval,
    terminal: snapshot,
  );

  ToolEvent withApproval(bool awaiting) => awaitingApproval == awaiting
      ? this
      : ToolEvent(
          id: id,
          toolCallId: toolCallId,
          title: title,
          kind: kind,
          status: status,
          content: content,
          locations: locations,
          rawInput: rawInput,
          rawOutput: rawOutput,
          awaitingApproval: awaiting,
          terminal: terminal,
        );

  static ToolEventStatus statusOf(ToolStatus status) => switch (status) {
    ToolStatus.pending => ToolEventStatus.pending,
    ToolStatus.inProgress => ToolEventStatus.running,
    ToolStatus.completed => ToolEventStatus.completed,
    ToolStatus.failed => ToolEventStatus.failed,
  };

  // Tool events are replaced, never mutated: identity is enough to tell
  // whether a row changed.
}

/// The agent's current to-do list for this turn.
class PlanMsg extends ChatMessage {
  final List<PlanEntry> entries;
  const PlanMsg({required super.id, required this.entries});
}

/// Something the agent or Baya wants the user to know (`notice`).
class NoticeMsg extends ChatMessage {
  /// `info`, `warning` or `error`.
  final String severity;
  final String text;

  /// The agent that needs a sign-in, when that is what this is about.
  final String? authAgent;
  const NoticeMsg({
    required super.id,
    required this.severity,
    required this.text,
    this.authAgent,
  });
}

/// An image the agent showed.
class AgentImageMsg extends ChatMessage {
  final MessageImage image;
  const AgentImageMsg({required super.id, required this.image});
}

/// A context compaction, with the agent's summary once it has one.
class CompactionMsg extends ChatMessage {
  final String summary;
  final bool done;
  const CompactionMsg({
    required super.id,
    this.summary = '',
    this.done = false,
  });
}
