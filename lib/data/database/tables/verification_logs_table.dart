import 'package:drift/drift.dart';

import 'users_table.dart';

/// Append-only log of every verification attempt. One row per pipeline
/// outcome (granted / denied / error / rateLimited / spoof / lowLight / …).
///
/// See docs/verification/architecture_recommendations.md §5.1 and §7.1.
///
/// Wire schema:
/// - `userId` is the matched user's id on success, NULL on no-match (so we can
///   still tune thresholds and record spoof attempts).
/// - `bestSimilarity` is the cosine score for the best candidate at decision
///   time, bounded `[-1, 1]`. We **never** store the embedding itself.
/// - `failureReason` is the string form of `VerificationFailure` (see the
///   domain layer); kept as TEXT so the enum can grow without a migration.
@DataClassName('VerificationLogRow')
class VerificationLogs extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Foreign key to `users.userId`. Nullable for "no match" / spoof rows. We
  /// use ON DELETE SET NULL so deleting a user keeps the log row for forensic
  /// completeness — see architecture_recommendations.md §M Test MGR-009.
  TextColumn get userId => text()
      .nullable()
      .references(Users, #userId, onDelete: KeyAction.setNull)();

  DateTimeColumn get at => dateTime()();

  /// One of: granted / denied / error / rateLimited / spoof / lowLight /
  /// occluded / multiFace / noFace / blinkRequired / qualityFailed / timeout.
  TextColumn get outcome => text()();

  TextColumn get failureReason => text().nullable()();

  RealColumn get bestSimilarity => real().nullable()();

  IntColumn get latencyMs => integer()();

  @override
  String get tableName => 'verification_logs';
}
