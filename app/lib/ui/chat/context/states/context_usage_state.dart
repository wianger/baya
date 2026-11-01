import 'package:app/domain/entities/context_usage.dart';

sealed class ContextUsageState {
  const ContextUsageState();
}

final class ContextUsageLoading extends ContextUsageState {
  const ContextUsageLoading();
}

final class ContextUsageReady extends ContextUsageState {
  const ContextUsageReady(this.usage);
  final ContextUsageSnapshot usage;
}

final class ContextUsageError extends ContextUsageState {
  const ContextUsageError(this.message);
  final String message;
}
