import 'package:app/domain/entities/context_usage.dart';

abstract class IContextUsageRepository {
  Future<ContextUsageSnapshot> fetch();
}

class ContextUsageFailure implements Exception {
  const ContextUsageFailure(this.message);
  final String message;
}
