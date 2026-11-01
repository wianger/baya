import 'package:app/domain/contracts/context_usage_repository.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import '../states/context_usage_state.dart';

class ContextUsageViewModel extends ViewModel<ContextUsageState> {
  ContextUsageViewModel(this._repository) : super(const ContextUsageLoading());
  final IContextUsageRepository _repository;
  int _generation = 0;
  bool _disposed = false;
  Future<void> refresh() async {
    final generation = ++_generation;
    emit(const ContextUsageLoading());
    try {
      final value = await _repository.fetch();
      if (!_disposed && generation == _generation) {
        emit(ContextUsageReady(value));
      }
    } on ContextUsageFailure catch (error) {
      if (!_disposed && generation == _generation) {
        emit(ContextUsageError(error.message));
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
