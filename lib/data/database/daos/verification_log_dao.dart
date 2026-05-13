import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/verification_logs_table.dart';

part 'verification_log_dao.g.dart';

/// DAO for `verification_logs`. Append-only at this layer — purge is the only
/// delete path (90-day retention). See architecture_recommendations.md §5.4.
@DriftAccessor(tables: [VerificationLogs])
class VerificationLogDao extends DatabaseAccessor<AppDatabase>
    with _$VerificationLogDaoMixin {
  VerificationLogDao(super.db);

  Future<int> insertLog(VerificationLogsCompanion log) =>
      into(verificationLogs).insert(log);

  /// Most recent log row for the given user (or null if none).
  Future<VerificationLogRow?> latestForUser(String userId) {
    return (select(verificationLogs)
          ..where((t) => t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.desc(t.at)])
          ..limit(1))
        .getSingleOrNull();
  }

  /// Number of log rows for `userId` strictly after `since`. Used by the
  /// Manage Users screen ("verifications today" aggregate).
  Future<int> countSince(String userId, DateTime since) async {
    final count = countAll(filter: verificationLogs.userId.equals(userId) &
        verificationLogs.at.isBiggerThanValue(since));
    final row = await (selectOnly(verificationLogs)..addColumns([count]))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// Reactive feed of every log row for one user, newest first.
  Stream<List<VerificationLogRow>> watchByUser(String userId) {
    return (select(verificationLogs)
          ..where((t) => t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.desc(t.at)]))
        .watch();
  }

  /// 90-day retention sweep. Run on app start.
  Future<int> purgeOlderThan(DateTime cutoff) {
    return (delete(verificationLogs)..where((t) => t.at.isSmallerThanValue(cutoff)))
        .go();
  }

  /// C2: count-bounded retention sweep. Keeps the [maxRows] most-recent
  /// rows (ordered by `at` descending) and deletes the rest. Run on app
  /// start alongside [purgeOlderThan].
  ///
  /// Implementation uses `NOT IN (SELECT … ORDER BY at DESC LIMIT N)` —
  /// Drift's query builder can't compose this in typed form, but the
  /// SQL is straightforward and benefits from the existing
  /// `idx_verification_logs_user_at` covering index. `maxRows = 0`
  /// deletes everything (the inner SELECT matches nothing → NOT IN is
  /// always true). Negative inputs are rejected — the caller has a
  /// programming error, not a runtime condition the DB should paper
  /// over.
  Future<int> purgeBeyondCount(int maxRows) {
    if (maxRows < 0) {
      throw ArgumentError.value(maxRows, 'maxRows', 'must be >= 0');
    }
    return customUpdate(
      'DELETE FROM verification_logs WHERE id NOT IN ('
      'SELECT id FROM verification_logs ORDER BY at DESC LIMIT ?)',
      variables: <Variable>[Variable.withInt(maxRows)],
      updates: <TableInfo>{verificationLogs},
    );
  }
}
