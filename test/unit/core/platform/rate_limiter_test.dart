import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/platform/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemorySecureStorage storage;
  late DateTime now;

  setUp(() {
    storage = InMemorySecureStorage();
    now = DateTime.utc(2026, 5, 10, 12);
  });

  RateLimiter newLimiter() => RateLimiter(
        storage: storage,
        clock: () => now,
      );

  test('first attempt: allowed with full quota', () async {
    final r = await newLimiter().check();
    expect(r, isA<RateLimitAllowed>());
    expect((r as RateLimitAllowed).remaining,
        FaceThresholds.rateLimitMaxFailures);
  });

  test('failures decrement remaining within window', () async {
    final l = newLimiter();
    for (var i = 1; i < FaceThresholds.rateLimitMaxFailures; i++) {
      await l.recordFailure();
      now = now.add(const Duration(seconds: 1));
      final r = await l.check();
      expect(r, isA<RateLimitAllowed>());
      expect((r as RateLimitAllowed).remaining,
          FaceThresholds.rateLimitMaxFailures - i);
    }
  });

  test('saturation engages cooldown', () async {
    final l = newLimiter();
    for (var i = 0; i < FaceThresholds.rateLimitMaxFailures; i++) {
      await l.recordFailure();
      now = now.add(const Duration(seconds: 1));
    }
    final r = await l.check();
    expect(r, isA<RateLimitCoolingDown>());
    final cd = r as RateLimitCoolingDown;
    expect(cd.retryAfter.inSeconds, lessThanOrEqualTo(
        const Duration(milliseconds: FaceThresholds.rateLimitCooldownMs)
            .inSeconds));
    expect(cd.retryAfter, greaterThan(Duration.zero));
  });

  test('cooldown expires → next attempt allowed', () async {
    final l = newLimiter();
    for (var i = 0; i < FaceThresholds.rateLimitMaxFailures; i++) {
      await l.recordFailure();
      now = now.add(const Duration(seconds: 1));
    }
    expect(await l.check(), isA<RateLimitCoolingDown>());

    // Advance past the cooldown window AND past the sliding window so
    // pruning clears all stale failures.
    now = now.add(const Duration(
      milliseconds: FaceThresholds.rateLimitWindowMs +
          FaceThresholds.rateLimitCooldownMs +
          1000,
    ));
    final r = await l.check();
    expect(r, isA<RateLimitAllowed>());
    expect((r as RateLimitAllowed).remaining,
        FaceThresholds.rateLimitMaxFailures);
  });

  test('reset clears all state', () async {
    final l = newLimiter();
    await l.recordFailure();
    await l.recordFailure();
    await l.reset();
    final r = await l.check();
    expect(r, isA<RateLimitAllowed>());
    expect((r as RateLimitAllowed).remaining,
        FaceThresholds.rateLimitMaxFailures);
  });

  test('failures older than the window are pruned', () async {
    final l = newLimiter();
    // 4 old failures (just under the limit), then advance past the window.
    for (var i = 0; i < FaceThresholds.rateLimitMaxFailures - 1; i++) {
      await l.recordFailure();
      now = now.add(const Duration(seconds: 1));
    }
    now = now.add(const Duration(
      milliseconds: FaceThresholds.rateLimitWindowMs + 1000,
    ));
    // After window expiry, the counter should be pruned to 0.
    final r = await l.check();
    expect(r, isA<RateLimitAllowed>());
    expect((r as RateLimitAllowed).remaining,
        FaceThresholds.rateLimitMaxFailures);
  });

  test('state persists across instances (same storage)', () async {
    final a = newLimiter();
    await a.recordFailure();
    await a.recordFailure();

    final b = newLimiter();
    final r = await b.check();
    expect(r, isA<RateLimitAllowed>());
    expect((r as RateLimitAllowed).remaining,
        FaceThresholds.rateLimitMaxFailures - 2);
  });

  test('clock running backward does not lift cooldown early', () async {
    final l = newLimiter();
    for (var i = 0; i < FaceThresholds.rateLimitMaxFailures; i++) {
      await l.recordFailure();
      now = now.add(const Duration(seconds: 1));
    }
    expect(await l.check(), isA<RateLimitCoolingDown>());

    // Adversary turns the clock back 1 hour.
    now = now.subtract(const Duration(hours: 1));
    // Cooldown is still in force because the stored cooldownUntil is
    // strictly after `now`.
    expect(await l.check(), isA<RateLimitCoolingDown>());
  });

  test('corrupt persisted state is reset, not crashed', () async {
    await storage.write('rl:verify', '{not valid json');
    final r = await newLimiter().check();
    expect(r, isA<RateLimitAllowed>());
    expect((r as RateLimitAllowed).remaining,
        FaceThresholds.rateLimitMaxFailures);
  });
}
