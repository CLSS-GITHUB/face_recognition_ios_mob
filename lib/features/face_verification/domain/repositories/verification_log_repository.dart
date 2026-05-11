import '../entities/verification_log.dart';

/// Domain port for persisting verification attempt outcomes. The data-layer
/// implementation (a follow-up slice) will adapt this to
/// `VerificationLogDao`.
///
/// Append-only: the only delete path is [purgeOlderThan], used by the
/// retention sweep scheduled by `verificationLogPurgeProvider` on app
/// start. Default window: [FaceThresholds.verificationLogRetentionDays].
abstract class VerificationLogRepository {
  Future<void> append(VerificationLog log);

  /// Deletes rows with `at < cutoff`. Returns the number of rows removed.
  Future<int> purgeOlderThan(DateTime cutoff);
}
