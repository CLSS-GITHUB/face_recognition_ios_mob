@TestOn('vm')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:face_ios_android/data/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the additive v1 → v2 schema migration. See
/// `docs/verification/architecture_recommendations.md` §5.1–5.2.
///
/// The test seeds a fake "v1" database (the original `users` table only,
/// `user_version = 1`) and then opens it with the current `AppDatabase`,
/// which forces drift's `onUpgrade(1, 2)` to run. Assertions cover:
/// 1. Existing rows preserved verbatim.
/// 2. Three new columns on `users`.
/// 3. New `verification_logs` table + secondary index.
/// 4. New writes round-trip through both DAOs.
void main() {
  group('Schema v1 -> v2 migration (additive)', () {
    test('preserves existing user rows and adds v2 columns + table', () async {
      final db = AppDatabase(_v1MemoryExecutor());
      addTearDown(db.close);

      // Force a query — drift opens the connection lazily and runs
      // onUpgrade as a side-effect of the first read.
      final cols = await _columnNames(db, 'users');

      expect(cols, containsAll(<String>[
        'user_id',
        'name',
        'face_templates',
        'is_active',
        'image_path',
        'enrolled_at',
        'last_verified_at',
        'template_meta',
        // v3 — face-recognition model version that produced the stored
        // templates. Pre-v3 rows default to 0 (= "legacy / unknown",
        // surfaces in the domain layer as User.requiresReEnroll).
        'model_version',
      ]));

      // Original v1 row is still there.
      final preserved = await db.userDao.getUserById('U1');
      expect(preserved, isNotNull);
      expect(preserved!.name, 'Alice');
      expect(preserved.isActive, isTrue);
      // Pre-v2 rows have no enrolment timestamp recorded — that column is
      // nullable for exactly this reason; new inserts use `clientDefault`.
      expect(preserved.enrolledAt, isNull);
      expect(preserved.lastVerifiedAt, isNull);
      expect(preserved.templateMeta, isNull);

      // New rows inserted post-migration pick up `clientDefault` for
      // `enrolledAt`.
      await db.userDao.insertUser(
        UsersCompanion.insert(
          userId: 'U2',
          name: 'Bob',
          faceTemplates: Uint8List.fromList(<int>[0]),
        ),
      );
      final fresh = await db.userDao.getUserById('U2');
      expect(fresh!.enrolledAt, isNotNull);
      final lag = DateTime.now().toUtc().difference(fresh.enrolledAt!.toUtc());
      expect(lag.inMinutes.abs() < 2, isTrue);

      // verification_logs table exists.
      final logCols = await _columnNames(db, 'verification_logs');
      expect(logCols, containsAll(<String>[
        'id',
        'user_id',
        'at',
        'outcome',
        'failure_reason',
        'best_similarity',
        'latency_ms',
      ]));

      // Index created.
      final indices = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = 'verification_logs'",
      ).get();
      expect(
        indices.any((r) => r.read<String>('name') ==
            'idx_verification_logs_user_at'),
        isTrue,
      );
    });

    test('verification_logs DAO round-trip after migration', () async {
      final db = AppDatabase(_v1MemoryExecutor());
      addTearDown(db.close);

      await db.verificationLogDao.insertLog(
        VerificationLogsCompanion.insert(
          userId: const Value('U1'),
          at: DateTime.utc(2026, 5, 10, 12, 0),
          outcome: 'granted',
          latencyMs: 412,
          bestSimilarity: const Value(0.84),
        ),
      );
      await db.verificationLogDao.insertLog(
        VerificationLogsCompanion.insert(
          userId: const Value(null),
          at: DateTime.utc(2026, 5, 10, 12, 1),
          outcome: 'denied',
          failureReason: const Value('noMatch'),
          bestSimilarity: const Value(0.41),
          latencyMs: 388,
        ),
      );

      final latest = await db.verificationLogDao.latestForUser('U1');
      expect(latest, isNotNull);
      expect(latest!.outcome, 'granted');
      expect(latest.bestSimilarity, closeTo(0.84, 1e-6));

      final today = await db.verificationLogDao
          .countSince('U1', DateTime.utc(2026, 5, 10));
      expect(today, 1);

      // Set lastVerifiedAt via the new DAO method and read it back. Compare
      // by moment because drift stores DateTime as epoch seconds.
      final stamp = DateTime.utc(2026, 5, 10, 12, 5);
      await db.userDao.touchLastVerified('U1', stamp);
      final after = await db.userDao.getUserById('U1');
      expect(after!.lastVerifiedAt, isNotNull);
      expect(after.lastVerifiedAt!.isAtSameMomentAs(stamp), isTrue);
    });

    test('v3 model_version: legacy rows default to 0, new rows can pick a value',
        () async {
      final db = AppDatabase(_v1MemoryExecutor());
      addTearDown(db.close);

      // Legacy row migrated from v1 → v3 should land at 0 (the column
      // default applied by ALTER TABLE ADD COLUMN ... DEFAULT 0).
      final legacy = await db.userDao.getUserById('U1');
      expect(legacy!.modelVersion, 0,
          reason: 'Pre-v3 rows must surface as legacy / re-enroll candidates.');

      // New inserts can set the version explicitly via the companion.
      await db.userDao.insertUser(
        UsersCompanion.insert(
          userId: 'U-new',
          name: 'Charlie',
          faceTemplates: Uint8List.fromList(<int>[0]),
          modelVersion: const Value(1),
        ),
      );
      final inserted = await db.userDao.getUserById('U-new');
      expect(inserted!.modelVersion, 1);
    });

    test('purgeOlderThan deletes only old log rows', () async {
      final db = AppDatabase(_v1MemoryExecutor());
      addTearDown(db.close);

      final old = DateTime.utc(2025, 1, 1);
      final fresh = DateTime.utc(2026, 5, 10);

      await db.verificationLogDao.insertLog(
        VerificationLogsCompanion.insert(
          userId: const Value('U1'),
          at: old,
          outcome: 'granted',
          latencyMs: 100,
        ),
      );
      await db.verificationLogDao.insertLog(
        VerificationLogsCompanion.insert(
          userId: const Value('U1'),
          at: fresh,
          outcome: 'granted',
          latencyMs: 100,
        ),
      );

      final removed = await db.verificationLogDao
          .purgeOlderThan(DateTime.utc(2026, 2, 10));
      expect(removed, 1);

      final rest = await db.customSelect(
        'SELECT COUNT(*) AS c FROM verification_logs',
      ).getSingle();
      expect(rest.read<int>('c'), 1);
    });
  });
}

/// Builds a NativeDatabase.memory() that already contains the v1 schema and a
/// seeded user, with `PRAGMA user_version = 1` so drift will run onUpgrade
/// the first time it opens the connection.
QueryExecutor _v1MemoryExecutor() {
  return NativeDatabase.memory(setup: (raw) {
    raw.execute('PRAGMA user_version = 1');
    raw.execute('''
      CREATE TABLE IF NOT EXISTS users (
        user_id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        face_templates BLOB NOT NULL,
        is_active INTEGER NOT NULL
          DEFAULT 1
          CHECK ("is_active" IN (0, 1)),
        image_path TEXT
      )
    ''');
    final seed = raw.prepare(
      'INSERT INTO users (user_id, name, face_templates, is_active, image_path) '
      'VALUES (?, ?, ?, ?, ?)',
    );
    seed.execute(<Object?>[
      'U1',
      'Alice',
      Uint8List.fromList(<int>[0]),
      1,
      null,
    ]);
    seed.dispose();
  });
}

Future<Set<String>> _columnNames(AppDatabase db, String table) async {
  final rows = await db
      .customSelect("PRAGMA table_info('$table')")
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}
