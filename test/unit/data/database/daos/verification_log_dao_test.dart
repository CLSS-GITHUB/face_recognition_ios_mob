@TestOn('vm')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:face_ios_android/data/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // Seed a user so `userId` foreign keys are valid for the typed paths.
    await db.userDao.insertUser(
      UsersCompanion.insert(
        userId: 'U1',
        name: 'Alice',
        faceTemplates: Uint8List.fromList(<int>[0]),
      ),
    );
    await db.userDao.insertUser(
      UsersCompanion.insert(
        userId: 'U2',
        name: 'Bob',
        faceTemplates: Uint8List.fromList(<int>[0]),
      ),
    );
  });

  tearDown(() => db.close());

  test('latestForUser returns the most recent row', () async {
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U1'),
        at: DateTime.utc(2026, 5, 10, 8),
        outcome: 'denied',
        latencyMs: 400,
        bestSimilarity: const Value(0.20),
      ),
    );
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U1'),
        at: DateTime.utc(2026, 5, 10, 9),
        outcome: 'granted',
        latencyMs: 380,
        bestSimilarity: const Value(0.91),
      ),
    );
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U2'),
        at: DateTime.utc(2026, 5, 10, 10),
        outcome: 'granted',
        latencyMs: 360,
        bestSimilarity: const Value(0.88),
      ),
    );

    final latest = await db.verificationLogDao.latestForUser('U1');
    expect(latest, isNotNull);
    expect(latest!.outcome, 'granted');
    // Drift round-trips DateTime through epoch seconds, so the local-vs-UTC
    // representation flips — compare moment-in-time, not structural fields.
    expect(latest.at.isAtSameMomentAs(DateTime.utc(2026, 5, 10, 9)), isTrue);
  });

  test('countSince counts only post-cutoff rows for the user', () async {
    final cutoff = DateTime.utc(2026, 5, 10);
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U1'),
        at: cutoff.subtract(const Duration(hours: 1)),
        outcome: 'granted',
        latencyMs: 1,
      ),
    );
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U1'),
        at: cutoff.add(const Duration(hours: 1)),
        outcome: 'granted',
        latencyMs: 1,
      ),
    );
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U1'),
        at: cutoff.add(const Duration(hours: 2)),
        outcome: 'denied',
        latencyMs: 1,
      ),
    );
    // Different user — must not contribute.
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U2'),
        at: cutoff.add(const Duration(hours: 1)),
        outcome: 'granted',
        latencyMs: 1,
      ),
    );

    expect(await db.verificationLogDao.countSince('U1', cutoff), 2);
    expect(await db.verificationLogDao.countSince('U2', cutoff), 1);
  });

  test('purgeOlderThan removes only old rows; recent rows preserved',
      () async {
    final old = DateTime.utc(2025, 1, 1);
    final recent = DateTime.utc(2026, 5, 1);
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U1'),
        at: old,
        outcome: 'granted',
        latencyMs: 1,
      ),
    );
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U1'),
        at: recent,
        outcome: 'granted',
        latencyMs: 1,
      ),
    );

    final removed = await db.verificationLogDao
        .purgeOlderThan(DateTime.utc(2026, 2, 1));
    expect(removed, 1);

    final remaining = await db
        .customSelect('SELECT COUNT(*) AS c FROM verification_logs')
        .getSingle();
    expect(remaining.read<int>('c'), 1);
  });

  test('null userId is allowed (spoof / no-match paths)', () async {
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value(null),
        at: DateTime.utc(2026, 5, 10, 12),
        outcome: 'spoof',
        failureReason: const Value('staticImage'),
        latencyMs: 250,
      ),
    );
    final all = await db
        .customSelect('SELECT user_id, outcome FROM verification_logs')
        .get();
    expect(all, hasLength(1));
    expect(all.first.read<String?>('user_id'), isNull);
    expect(all.first.read<String>('outcome'), 'spoof');
  });

  test('deleting the user nulls userId on existing log rows', () async {
    await db.verificationLogDao.insertLog(
      VerificationLogsCompanion.insert(
        userId: const Value('U1'),
        at: DateTime.utc(2026, 5, 10),
        outcome: 'granted',
        latencyMs: 1,
      ),
    );
    final aliceRow = (await db.userDao.getUserById('U1'))!;
    await db.userDao.deleteUser(aliceRow);

    final survivors = await db
        .customSelect('SELECT user_id FROM verification_logs')
        .get();
    expect(survivors, hasLength(1),
        reason: 'log row preserved per ON DELETE SET NULL contract');
    expect(survivors.first.read<String?>('user_id'), isNull);
  });
}
