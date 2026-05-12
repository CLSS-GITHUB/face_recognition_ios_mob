import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'daos/user_dao.dart';
import 'daos/verification_log_dao.dart';
import 'tables/users_table.dart';
import 'tables/verification_logs_table.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [Users, VerificationLogs],
  daos: [UserDao, VerificationLogDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'face_verification_db'));

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createVerificationLogIndex(m);
        },
        onUpgrade: (m, from, to) async {
          // Additive only. No fallbackToDestructiveMigration, ever.
          // See docs/migration/05_database_migration.md and
          // docs/verification/architecture_recommendations.md §5.2.
          if (from < 2) {
            await m.addColumn(users, users.enrolledAt);
            await m.addColumn(users, users.lastVerifiedAt);
            await m.addColumn(users, users.templateMeta);
            await m.createTable(verificationLogs);
            await _createVerificationLogIndex(m);
          }
          if (from < 3) {
            // model_version: int NOT NULL DEFAULT 0. Pre-v3 rows
            // (templates from any model that didn't track version) get
            // 0 and are filtered out of the active matching bank by
            // UserRepositoryImpl.activeFlatTemplates. Users surface as
            // `requiresReEnroll == true` so the UI can prompt a one-
            // time re-capture instead of silently failing every match.
            await m.addColumn(users, users.modelVersion);
          }
          if (from < 4) {
            // last_enrolled_at: nullable DateTime. Pre-v4 rows have no
            // per-template timestamp, so the entity falls back to
            // `enrolled_at` when reading. EnrollUser populates this on
            // every save going forward, which is what makes the age
            // check in User.isStaleAsOf actually defeat slow drift —
            // a user who re-enrols stays fresh even if their original
            // enrolledAt is years old.
            await m.addColumn(users, users.lastEnrolledAt);
          }
          if (from >= 2 && from < 5) {
            // pad_score: nullable REAL. F-10 instrumentation column.
            // Pre-v5 rows have NULL — they were captured before the PAD
            // pipeline existed, so there is no spoof score to backfill.
            // Going forward the verify use case writes one whenever PAD
            // ran on the attempt (NoOp emits 0.0, real models emit
            // a real spoof score; failures land as NULL).
            //
            // Guarded on `from >= 2`: a v1 origin reaches this point
            // having just created `verification_logs` fresh in the
            // block above, with `pad_score` already present in the
            // current table schema — re-adding here would duplicate
            // the column.
            await m.addColumn(verificationLogs, verificationLogs.padScore);
          }
        },
        // Foreign keys are off by default in SQLite. We need them on so that
        // `ON DELETE SET NULL` on `verification_logs.userId` actually fires
        // when a user row is deleted (architecture_recommendations.md §M
        // MGR-009 / §L VER-DB-010).
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// (userId, at DESC) covers the "verifications today" aggregate and the
  /// per-user latest lookup driven by Manage Users.
  Future<void> _createVerificationLogIndex(Migrator m) {
    return m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_verification_logs_user_at '
      'ON verification_logs (user_id, at DESC)',
    );
  }
}
