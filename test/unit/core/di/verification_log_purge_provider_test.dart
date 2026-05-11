import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/di/providers.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/verification_log.dart';
import 'package:face_ios_android/features/face_verification/domain/repositories/verification_log_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLogRepo implements VerificationLogRepository {
  DateTime? lastCutoff;
  int returnRowsRemoved = 0;
  Object? throwOnPurge;

  @override
  Future<void> append(VerificationLog log) async {}

  @override
  Future<int> purgeOlderThan(DateTime cutoff) async {
    lastCutoff = cutoff;
    if (throwOnPurge != null) throw throwOnPurge!;
    return returnRowsRemoved;
  }
}

void main() {
  test(
      'verificationLogPurgeProvider calls purgeOlderThan with the configured cutoff',
      () async {
    final fake = _FakeLogRepo()..returnRowsRemoved = 7;
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

  test('verificationLogPurgeProvider swallows errors and returns 0', () async {
    // Maintenance must never block app start. A db hiccup → returns 0.
    final fake = _FakeLogRepo()..throwOnPurge = StateError('db locked');
    final container = ProviderContainer(overrides: [
      verificationLogRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final removed = await container.read(verificationLogPurgeProvider.future);
    expect(removed, 0);
  });
}
