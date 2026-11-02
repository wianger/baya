/// One slash command, prompt template, or skill exposed by the active agent.
class AgentCommand {
  const AgentCommand({
    required this.name,
    required this.source,
    this.description = '',
  });

  final String name;
  final String source;
  final String description;

  @override
  bool operator ==(Object other) =>
      other is AgentCommand &&
      other.name == name &&
      other.source == source &&
      other.description == description;

  @override
  int get hashCode => Object.hash(name, source, description);
}

/// Slash-command discovery for one active session.
///
/// Agent-provided commands are paired with the typed actions accepted by the
/// Baya host. Keeping both values in one result prevents the palette from
/// offering a host action to a harness that cannot execute it.
class AgentCommandCatalog {
  const AgentCommandCatalog({this.commands = const [], this.supportedActions});

  final List<AgentCommand> commands;

  /// `null` until the session has reported its actions.
  final Set<String>? supportedActions;

  @override
  bool operator ==(Object other) =>
      other is AgentCommandCatalog &&
      _sameCommands(other.commands, commands) &&
      _sameActions(other.supportedActions, supportedActions);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(commands),
    supportedActions == null
        ? null
        : Object.hashAllUnordered(supportedActions!),
  );

  static bool _sameCommands(List<AgentCommand> a, List<AgentCommand> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  static bool _sameActions(Set<String>? a, Set<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    return a.containsAll(b);
  }
}
