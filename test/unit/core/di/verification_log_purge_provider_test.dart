import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/di/providers.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/verification_log.dart';
import 'package:face_ios_android/features/face_verification/domain/repositories/verification_log_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLogRepo implements VerificationLogRepository {
  DateTime? lastCutoff;
  int? lastMaxRows;
  int returnAgeRowsRemoved = 0;
  int returnCountRowsRemoved = 0;
  Object? throwOnAgePurge;
  Object? throwOnCountPurge;

  @override
  Future<void> append(VerificationLog log) async {}

  @override
  Future<int> purgeOlderThan(DateTime cutoff) async {
    lastCutoff = cutoff;
    if (throwOnAgePurge != null) throw throwOnAgePurge!;
    return returnAgeRowsRemoved;
  }

  @override
  Future<int> purgeBeyondCount(int maxRows) async {
    lastMaxRows = maxRows;
    if (throwOnCountPurge != null) throw throwOnCountPurge!;
    return returnCountRowsRemoved;
  }
}

void main() {
  test(
      'verificationLogPurgeProvider calls purgeOlderThan with the configured cutoff',
      () async {
    final fake = _FakeLogRepo()..returnAgeRowsRemoved = 7;
    final container = ProviderContainer(overrides: [
      verificationLogRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final before = DateTime.now().toUtc();
    final removed = await container.read(verificationLogPurgeProvider.future);
    final after = DateTime.now().toUtc();

    expect(removed, 7);
    expect(fake.lastCutoff, isNotNull);
    // Cutoff = now - retention. Bound it within the wall-clock window
    // bracketing the read; clock skew of microseconds shouldn't fail us.
    final expectedMin = before.subtract(
      const Duration(days: FaceThresholds.verificationLogRetentionDays),
    );
    final expectedMax = after.subtract(
      const Duration(days: FaceThresholds.verificationLogRetentionDays),
    );
    expect(
      fake.lastCutoff!.isAtSameMomentAs(expectedMin) ||
          fake.lastCutoff!.isAfter(expectedMin),
      isTrue,
    );
    expect(
      fake.lastCutoff!.isAtSameMomentAs(expectedMax) ||
          fake.lastCutoff!.isBefore(expectedMax),
      isTrue,
    );
  });

  test(
      'verificationLogPurgeProvider calls purgeBeyondCount with verificationLogMaxRows',
      () async {
    final fake = _FakeLogRepo()..returnCountRowsRemoved = 3;
    final container = ProviderContainer(overrides: [
      verificationLogRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    await container.read(verificationLogPurgeProvider.future);
    expect(fake.lastMaxRows, FaceThresholds.verificationLogMaxRows);
  });

  test('verificationLogPurgeProvider sums removals across both passes',
      () async {
    final fake = _FakeLogRepo()
      ..returnAgeRowsRemoved = 5
      ..returnCountRowsRemoved = 12;
    final container = ProviderContainer(overrides: [
      verificationLogRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final removed = await container.read(verificationLogPurgeProvider.future);
    expect(removed, 17);
  });

  test('age-purge failure does not lose count-purge result', () async {
    // The two passes are independently wrapped: if the age sweep
    // throws, the count sweep still runs and its contribution is
    // returned.
    final fake = _FakeLogRepo()
      ..throwOnAgePurge = StateError('age sweep failed')
      ..returnCountRowsRemoved = 42;
    final container = ProviderContainer(overrides: [
      verificationLogRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final removed = await container.read(verificationLogPurgeProvider.future);
    expect(removed, 42);
  });

  test('count-purge failure does not lose age-purge result', () async {
    final fake = _FakeLogRepo()
      ..returnAgeRowsRemoved = 9
      ..throwOnCountPurge = StateError('count sweep failed');
    final container = ProviderContainer(overrides: [
      verificationLogRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final removed = await container.read(verificationLogPurgeProvider.future);
    expect(removed, 9);
  });

  test('both passes failing → returns 0', () async {
    // Maintenance must never block app start. A db hiccup → returns 0.
    final fake = _FakeLogRepo()
      ..throwOnAgePurge = StateError('db locked')
      ..throwOnCountPurge = StateError('db still locked');
    final container = ProviderContainer(overrides: [
      verificationLogRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final removed = await container.read(verificationLogPurgeProvider.future);
    expect(removed, 0);
  });
}
