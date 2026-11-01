import 'package:app/domain/entities/agent_command.dart';
import 'package:app/domain/contracts/repository.dart';

abstract class IAgentCommandsRepository extends Repository {
  Future<AgentCommandCatalog> list();
}

class AgentCommandsFailure implements Exception {
  const AgentCommandsFailure(this.message);
  final String message;
}
