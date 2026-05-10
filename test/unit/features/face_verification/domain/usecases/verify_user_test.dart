import 'dart:typed_data';

import 'package:face_ios_android/core/constants/thresholds.dart';
import 'package:face_ios_android/core/error/failures.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/user.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/verification_failure.dart';
import 'package:face_ios_android/features/face_verification/domain/entities/verification_log.dart';
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
/// in tests by construction).
FlatTemplates _bank(List<(User, Float32List)> entries) {
  const dim = FaceThresholds.embeddingDim;
  final flat = Float32List(entries.length * dim);
  final map = <User>[];
  for (var i = 0; i < entries.length; i++) {
    flat.setRange(i * dim, (i + 1) * dim, entries[i].$2);
    map.add(entries[i].$1);
  }
  return FlatTemplates(flat: flat, map: map);
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
      templates: FlatTemplates(flat: _emptyF32, map: const <User>[]),
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
}

final Float32List _emptyF32 = Float32List(0);
