import '../entities/verification_log.dart';

/// Domain port for persisting verification attempt outcomes. The data-layer
/// implementation (a follow-up slice) will adapt this to
/// `VerificationLogDao`.
///
/// Append-only: the only delete paths are [purgeOlderThan] (age-based)
/// and [purgeBeyondCount] (count-based), both used by the cold-start
/// retention sweep scheduled by `verificationLogPurgeProvider`. Defaults:
/// [FaceThresholds.verificationLogRetentionDays] and
/// [FaceThresholds.verificationLogMaxRows].
abstract class VerificationLogRepository {
  Future<void> append(VerificationLog log);

  /// Deletes rows with `at < cutoff`. Returns the number of rows removed.
  Future<int> purgeOlderThan(DateTime cutoff);

  /// C2: deletes every row beyond the [maxRows] most recent (ordered by
  /// `at` descending). Returns the number of rows removed.
  ///
  /// Use case is heavy-use devices that saturate the age window faster
  /// than the 30-day sweep fires — say 1000 verifies/day producing 30k
  /// rows on disk well inside the age cap. Paired with [purgeOlderThan]
  /// the table is bounded by `min(age, count)`.
  Future<int> purgeBeyondCount(int maxRows);
}
