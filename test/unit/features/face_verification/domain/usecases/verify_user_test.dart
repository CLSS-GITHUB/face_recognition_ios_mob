import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/error/failures.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/user.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/verification_failure.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/verification_log.dart';
import 'package:face_ios_android/core/utils/frame_preparation.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/verify_decision.dart';
import 'package:face_ios_android/features/face_verification/domain/ports/embedding_extractor.dart';
import 'package:face_ios_android/features/face_verification/domain/ports/last_verified_sink.dart';
import 'package:face_ios_android/features/face_verification/domain/repositories/user_repository.dart';
import 'package:face_ios_android/features/face_verification/domain/repositories/verification_log_repository.dart';
import 'package:face_ios_android/features/face_verification/domain/usecases/verify_user.dart';
import 'package:face_ios_android/services/face_matching_service.dart';
import 'package:flutter_test/flutter_test.dart';

const int _payloadBytes =
    FaceThresholds.inputSize * FaceThresholds.inputSize * 3;

Uint8List _frame() => Uint8List(_payloadBytes);

/// Builds a flat-templates bank from a list of probes. Each user gets a
/// single template equal to its corresponding probe (already L2-normalised
/// in tests by construction). Uses the [FlatTemplates.fromMap] factory so
/// the parallel `userOf` / `uniqueUsers` indices required by the new
/// open-set matcher are derived automatically.
FlatTemplates _bank(List<(User, Float32List)> entries) {
  const dim = FaceThresholds.embeddingDim;
  final flat = Float32List(entries.length * dim);
  final map = <User>[];
  for (var i = 0; i < entries.length; i++) {
    flat.setRange(i * dim, (i + 1) * dim, entries[i].$2);
    map.add(entries[i].$1);
  }
  return FlatTemplates.fromMap(flat: flat, map: map);
}

User _user(String id) => User(
      userId: id,
      name: 'User $id',
      faceTemplates: const <Float32List>[],
      isActive: true,
    );

/// Float32List that is purely along axis `i` — `cosine(eFor(i), eFor(j))`
/// is 1 when `i == j` and 0 otherwise.
Float32List _eFor(int axis) {
  final v = Float32List(FaceThresholds.embeddingDim);
  v[axis] = 1.0;
  return v;
}

class _FakeExtractor implements EmbeddingExtractor {
  _FakeExtractor.returns(this._embedding);
  _FakeExtractor.throwing(this._error);

  Float32List? _embedding;
  Object? _error;
  int calls = 0;

  @override
  Future<Float32List> extract(Uint8List rgb112) async {
    calls++;
    final err = _error;
    if (err != null) {
      // ignore: only_throw_errors
      throw err;
    }
    return _embedding!;
  }

  @override
  Future<Uint8List> prepare({
    required Uint8List rawBytes,
    required int width,
    required int height,
    required RawFrameFormat format,
    required Rect bbox,
    int? leftEyeX,
    int? leftEyeY,
    int? rightEyeX,
    int? rightEyeY,
  }) async {
    // VerifyUser never calls prepare — preparation is the controller's
    // job. Unreachable from anything the use case tests exercise; if it
    // ever does get hit, fail loudly instead of pretending success.
    throw UnimplementedError(
        '_FakeExtractor.prepare is not used by VerifyUser tests');
  }
}

class _FakeSink implements LastVerifiedSink {
  final List<(String, DateTime)> calls = <(String, DateTime)>[];

  @override
  Future<void> touchLastVerified(String userId, DateTime when) async {
    calls.add((userId, when));
  }
}

class _FakeLogRepo implements VerificationLogRepository {
  final List<VerificationLog> appended = <VerificationLog>[];
  int purgeCalls = 0;

  @override
  Future<void> append(VerificationLog log) async {
    appended.add(log);
  }

  @override
  Future<int> purgeOlderThan(DateTime cutoff) async {
    purgeCalls++;
    return 0;
  }
}

void main() {
  late _FakeSink sink;
  late _FakeLogRepo logRepo;
  const matcher = FaceMatchingService();

  setUp(() {
    sink = _FakeSink();
    logRepo = _FakeLogRepo();
  });

  test('granted: similarity >= threshold → touch + log + return user',
      () async {
    final alice = _user('U1');
    final probe = _eFor(0); // exactly matches alice's template at cosine=1
    final extractor = _FakeExtractor.returns(probe);

    final useCase = VerifyUser(
      extractor: extractor,
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
      clock: () => DateTime.utc(2026, 5, 10, 12),
    );
    final bank = _bank(<(User, Float32List)>[(alice, _eFor(0))]);

    final decision = await useCase.call(rgb112: _frame(), templates: bank);

    expect(decision, isA<VerifyGranted>());
    final granted = decision as VerifyGranted;
    expect(granted.user.userId, 'U1');
    expect(granted.similarity, closeTo(1.0, 1e-6));
    expect(granted.latencyMs, greaterThanOrEqualTo(0));

    expect(sink.calls, hasLength(1));
    expect(sink.calls.single.$1, 'U1');
    expect(sink.calls.single.$2, DateTime.utc(2026, 5, 10, 12));

    expect(logRepo.appended, hasLength(1));
    final log = logRepo.appended.single;
    expect(log.outcome, VerificationOutcome.granted);
    expect(log.userId, 'U1');
    expect(log.failureReason, isNull);
    expect(log.bestSimilarity, closeTo(1.0, 1e-6));
  });

  test('denied: best similarity below threshold → log denied with bestSim',
      () async {
    final alice = _user('U1');
    // Probe orthogonal to alice's template — cosine = 0 (< 0.75 threshold).
    final extractor = _FakeExtractor.returns(_eFor(1));

    final useCase = VerifyUser(
      extractor: extractor,
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );
    final bank = _bank(<(User, Float32List)>[(alice, _eFor(0))]);

    final decision = await useCase.call(rgb112: _frame(), templates: bank);

    expect(decision, isA<VerifyDenied>());
    final denied = decision as VerifyDenied;
    expect(denied.reason, VerificationFailure.noMatch);
    expect(denied.bestSimilarity, closeTo(0.0, 1e-6));

    expect(sink.calls, isEmpty);
    expect(logRepo.appended, hasLength(1));
    final log = logRepo.appended.single;
    expect(log.outcome, VerificationOutcome.denied);
    expect(log.userId, isNull);
    expect(log.failureReason, VerificationFailure.noMatch.wireName);
    expect(log.bestSimilarity, closeTo(0.0, 1e-6));
  });

  test('granted picks highest-similarity user in a multi-user bank',
      () async {
    final alice = _user('U1');
    final bob = _user('U2');
    final carol = _user('U3');
    // Probe is mostly along axis 1 → matches bob (template axis 1) best.
    final probe = _eFor(1);
    final extractor = _FakeExtractor.returns(probe);

    final useCase = VerifyUser(
      extractor: extractor,
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );
    final bank = _bank(<(User, Float32List)>[
      (alice, _eFor(0)),
      (bob, _eFor(1)),
      (carol, _eFor(2)),
    ]);

    final decision = await useCase.call(rgb112: _frame(), templates: bank);

    expect(decision, isA<VerifyGranted>());
    expect((decision as VerifyGranted).user.userId, 'U2');
  });

  test(
      'multi-user margin: deny when two users are within `verifyUserMargin`',
      () async {
    // Construct a 3-user bank where the *correct* user (alice) has a
    // template very close to a *wrong* user (bob). Both clear the
    // 0.75 threshold, but their gap is below `verifyUserMargin`. The
    // new open-set check must deny rather than grant the runner-up.
    final alice = _user('U1');
    final bob = _user('U2');
    final carol = _user('U3');

    Float32List along(double a, double b) {
      // Build a 2-D probe in axes (0, 1) embedded into a 192-D space,
      // then L2-normalise. Carol stays orthogonal so she never wins.
      final v = Float32List(FaceThresholds.embeddingDim);
      v[0] = a;
      v[1] = b;
      final n = sqrt(a * a + b * b);
      if (n == 0) return v;
      for (var i = 0; i < v.length; i++) {
        v[i] /= n;
      }
      return v;
    }

    // alice ≈ (1, 0) and bob ≈ (cos15°, sin15°). probe ≈ (cos8°, sin8°).
    // cosines: probe·alice = cos8° ≈ 0.990; probe·bob = cos7° ≈ 0.993.
    // Both clear 0.75. The gap between them is ≈ 0.003 — well inside
    // the 0.04 margin floor, so the use case must deny.
    final aliceT = along(1.0, 0.0);
    final bobT = along(0.966, 0.259); // ~15° from axis 0
    final probe = along(0.990, 0.139); // ~8° from axis 0
    final extractor = _FakeExtractor.returns(probe);

    final useCase = VerifyUser(
      extractor: extractor,
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );
    final bank = _bank(<(User, Float32List)>[
      (alice, aliceT),
      (bob, bobT),
      (carol, _eFor(2)),
    ]);

    final decision = await useCase.call(rgb112: _frame(), templates: bank);

    expect(decision, isA<VerifyDenied>(),
        reason:
            'Two enrolled users within verifyUserMargin should deny, not grant.');
    final denied = decision as VerifyDenied;
    expect(denied.reason, VerificationFailure.noMatch);
    // The best similarity is still recorded for tuning telemetry.
    expect(denied.bestSimilarity, isNotNull);
    expect(denied.bestSimilarity!, greaterThan(FaceThresholds.verifyThreshold));
    expect(sink.calls, isEmpty,
        reason: 'No user should be touched when the margin gate denies.');
  });

  test(
      'multi-user margin: grant when winner clears margin over runner-up',
      () async {
    // Same bank shape as the margin-deny test, but probe is shifted so
    // alice wins by a wide margin (> verifyUserMargin = 0.04).
    final alice = _user('U1');
    final bob = _user('U2');
    final carol = _user('U3');

    Float32List along(double a, double b) {
      final v = Float32List(FaceThresholds.embeddingDim);
      v[0] = a;
      v[1] = b;
      final n = sqrt(a * a + b * b);
      for (var i = 0; i < v.length; i++) {
        v[i] /= n;
      }
      return v;
    }

    final aliceT = along(1.0, 0.0);
    final bobT = along(0.5, 0.866); // ~60° from axis 0
    final probe = along(0.985, 0.174); // ~10° from axis 0
    // probe·alice = cos10° ≈ 0.985; probe·bob = cos50° ≈ 0.643.
    // alice wins by ≈ 0.34 — way above the 0.04 margin.
    final extractor = _FakeExtractor.returns(probe);

    final useCase = VerifyUser(
      extractor: extractor,
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );
    final bank = _bank(<(User, Float32List)>[
      (alice, aliceT),
      (bob, bobT),
      (carol, _eFor(2)),
    ]);

    final decision = await useCase.call(rgb112: _frame(), templates: bank);

    expect(decision, isA<VerifyGranted>());
    expect((decision as VerifyGranted).user.userId, 'U1');
    expect(decision.similarity, greaterThan(FaceThresholds.verifyThreshold));
  });

  test('empty bank: skip extract and log denied with noMatch', () async {
    final extractor = _FakeExtractor.returns(_eFor(0));
    final useCase = VerifyUser(
      extractor: extractor,
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );

    final decision = await useCase.call(
      rgb112: _frame(),
      templates: FlatTemplates.empty,
    );

    expect(decision, isA<VerifyDenied>());
    expect((decision as VerifyDenied).reason, VerificationFailure.noMatch);
    expect(extractor.calls, 0,
        reason: 'No isolate roundtrip when there are no candidates');
    expect(sink.calls, isEmpty);

    expect(logRepo.appended, hasLength(1));
    expect(logRepo.appended.single.outcome, VerificationOutcome.denied);
    expect(logRepo.appended.single.bestSimilarity, isNull);
  });

  test(
      'EmbeddingFailedError → denied with reason=extractionFailed, '
      'log outcome=error', () async {
    final extractor = _FakeExtractor.throwing(const EmbeddingFailedError());
    final useCase = VerifyUser(
      extractor: extractor,
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );
    final bank = _bank(<(User, Float32List)>[(_user('U1'), _eFor(0))]);

    final decision = await useCase.call(rgb112: _frame(), templates: bank);

    expect(decision, isA<VerifyDenied>());
    expect((decision as VerifyDenied).reason,
        VerificationFailure.extractionFailed);
    expect(sink.calls, isEmpty);
    expect(logRepo.appended.single.outcome, VerificationOutcome.error);
  });

  test('any other extractor exception → denied/error, log outcome=error',
      () async {
    final extractor = _FakeExtractor.throwing(
      StateError('isolate is busy'),
    );
    final useCase = VerifyUser(
      extractor: extractor,
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );
    final bank = _bank(<(User, Float32List)>[(_user('U1'), _eFor(0))]);

    final decision = await useCase.call(rgb112: _frame(), templates: bank);

    expect((decision as VerifyDenied).reason, VerificationFailure.error);
    expect(logRepo.appended.single.outcome, VerificationOutcome.error);
    expect(logRepo.appended.single.failureReason,
        VerificationFailure.error.wireName);
  });

  test('latencyMs is non-negative on every path', () async {
    final useCase = VerifyUser(
      extractor: _FakeExtractor.returns(_eFor(0)),
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );
    final bank = _bank(<(User, Float32List)>[(_user('U1'), _eFor(0))]);
    final granted = await useCase.call(rgb112: _frame(), templates: bank);
    expect(granted.latencyMs, greaterThanOrEqualTo(0));

    final useCaseFail = VerifyUser(
      extractor: _FakeExtractor.throwing(const EmbeddingFailedError()),
      matcher: matcher,
      userSink: sink,
      logRepo: logRepo,
    );
    final denied = await useCaseFail.call(rgb112: _frame(), templates: bank);
    expect(denied.latencyMs, greaterThanOrEqualTo(0));
  });

  group('O-5 fast path: pre-extracted embedding', () {
    test('skips extractor.extract entirely when embedding is supplied',
        () async {
      // If the use case touches the extractor when `embedding` is set we
      // would silently regress the latency win. The fake's `calls`
      // counter is the canary.
      final probe = _eFor(0);
      final extractor = _FakeExtractor.returns(_eFor(99))
        ..calls = 0; // sanity-reset the counter
      final useCase = VerifyUser(
        extractor: extractor,
        matcher: matcher,
        userSink: sink,
        logRepo: logRepo,
        clock: () => DateTime.utc(2026, 5, 11, 12),
      );
      final bank = _bank(<(User, Float32List)>[(_user('U1'), _eFor(0))]);

      final decision =
          await useCase.call(embedding: probe, templates: bank);
      expect(decision, isA<VerifyGranted>());
      expect(extractor.calls, 0,
          reason: 'fast path must not call the extractor');
    });

    test('fast-path probe is zeroed after the call (defense-in-depth)',
        () async {
      // The use case's `finally` block zeroes the probe regardless of
      // whether it came from the extractor or the caller. The
      // controller relies on this — losing it would leak a live
      // embedding past the match.
      final probe = _eFor(0);
      final useCase = VerifyUser(
        extractor: _FakeExtractor.returns(_eFor(99)),
        matcher: matcher,
        userSink: sink,
        logRepo: logRepo,
      );
      final bank = _bank(<(User, Float32List)>[(_user('U1'), _eFor(0))]);
      await useCase.call(embedding: probe, templates: bank);
      expect(probe.every((v) => v == 0), isTrue,
          reason: 'caller-supplied embedding must be wiped on return');
    });

    test('asserts exactly one of rgb112 / embedding is provided', () {
      final useCase = VerifyUser(
        extractor: _FakeExtractor.returns(_eFor(0)),
        matcher: matcher,
        userSink: sink,
        logRepo: logRepo,
      );
      final bank = _bank(<(User, Float32List)>[(_user('U1'), _eFor(0))]);
      // Both null → asserts in debug.
      expect(
        () => useCase.call(templates: bank),
        throwsA(isA<AssertionError>()),
      );
      // Both present → asserts in debug.
      expect(
        () => useCase.call(
          rgb112: _frame(),
          embedding: _eFor(0),
          templates: bank,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
