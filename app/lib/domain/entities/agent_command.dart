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
