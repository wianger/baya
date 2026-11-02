import 'package:app/domain/contracts/agent_commands_repository.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/commands/states/agent_commands_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

class AgentCommandsViewModel extends ViewModel<AgentCommandsState> {
  AgentCommandsViewModel(this._repository) : super(const AgentCommandsState());

  final IAgentCommandsRepository _repository;
  bool _disposed = false;

  Future<void> refresh() async {
    if (state.loading) return;
    emit(
      AgentCommandsState(
        commands: state.commands,
        supportedActions: state.supportedActions,
        loading: true,
      ),
    );
    try {
      final catalogue = await _repository.list();
      if (!_disposed) {
        emit(
          AgentCommandsState(
            commands: catalogue.commands,
            supportedActions: catalogue.supportedActions,
          ),
        );
      }
    } on AgentCommandsFailure catch (error) {
      if (!_disposed) {
        emit(
          AgentCommandsState(
            commands: state.commands,
            supportedActions: state.supportedActions,
            error: error.message,
          ),
        );
      }
    } catch (_) {
      if (!_disposed) {
        emit(
          AgentCommandsState(
            commands: state.commands,
            supportedActions: state.supportedActions,
            error: appL10n.couldNotLoadCommands,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
