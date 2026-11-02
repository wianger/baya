import 'package:app/domain/entities/agent_command.dart';
import 'package:flutter/foundation.dart';

@immutable
class AgentCommandsState {
  const AgentCommandsState({
    this.commands = const [],
    this.loading = false,
    this.error,
  });

  final List<AgentCommand> commands;
  final bool loading;
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is AgentCommandsState &&
      listEquals(other.commands, commands) &&
      other.loading == loading &&
      other.error == error;

  @override
  int get hashCode => Object.hash(Object.hashAll(commands), loading, error);
}
