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
  int get schemaVersion => 3;

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
