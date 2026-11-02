import 'package:app/domain/entities/update_info.dart';

/// Fetches the release manifest. Best-effort: any failure (offline, 404,
/// invalid JSON, wrong schema) returns `null` and never throws.
abstract class UpdateChecker {
  Future<UpdateInfo?> fetchLatest();
}
