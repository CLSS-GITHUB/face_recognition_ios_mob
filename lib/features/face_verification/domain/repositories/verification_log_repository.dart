import '../entities/verification_log.dart';

/// Domain port for persisting verification attempt outcomes. The data-layer
/// implementation (a follow-up slice) will adapt this to
/// `VerificationLogDao`.
///
/// Append-only: the only delete path is [purgeOlderThan], used by the
/// 90-day retention sweep on app start.
abstract class VerificationLogRepository {
  Future<void> append(VerificationLog log);

  /// Deletes rows with `at < cutoff`. Returns the number of rows removed.
  Future<int> purgeOlderThan(DateTime cutoff);
}
