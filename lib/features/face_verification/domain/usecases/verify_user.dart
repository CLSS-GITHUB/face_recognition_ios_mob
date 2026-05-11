import 'dart:typed_data';

import '../../../../core/constants/thresholds.dart';
import '../../../../core/error/failures.dart';
import '../../../../services/face_matching_service.dart';
import '../entities/verification_failure.dart';
import '../entities/verification_log.dart';
import '../entities/verify_decision.dart';
import '../ports/embedding_extractor.dart';
import '../ports/last_verified_sink.dart';
import '../repositories/user_repository.dart';
import '../repositories/verification_log_repository.dart';

/// Orchestrates the *expensive*, once-per-attempt half of the Verify Identity
/// pipeline. Cheap per-frame gates (detection, quality, occlusion, liveness,
/// anti-replay) stay on the controller; this use case is invoked once a
/// candidate frame has already passed those.
///
/// Inputs:
///   - `rgb112`: pre-aligned, pre-resized 112×112 RGB byte buffer.
///   - `templates`: the active flat-template bank pre-warmed by the
///     controller on screen entry.
///
/// Output: a sealed [VerifyDecision] (granted or denied) with bookkeeping
/// already persisted (verification log row + `lastVerifiedAt` on success).
///
/// Open-set safety:
///   The matcher returns the *best user's* best similarity AND the
///   runner-up user's best similarity. We grant only when **both**
///   (a) the best similarity clears `verifyThreshold` AND
///   (b) the gap between best and runner-up clears `verifyUserMargin`.
///   This prevents identity confusion in deployments with ≥ 3 enrolled
///   users where an unrelated face can sometimes land in the noisy
///   0.75–0.85 cosine band against the live probe.
///
/// See `docs/verification/architecture_recommendations.md` §2.4 / §3.5 for
/// the surrounding pipeline.
class VerifyUser {
  VerifyUser({
    required EmbeddingExtractor extractor,
    required FaceMatchingService matcher,
    required LastVerifiedSink userSink,
    required VerificationLogRepository logRepo,
    DateTime Function()? clock,
  })  : _extractor = extractor,
        _matcher = matcher,
        _userSink = userSink,
        _logRepo = logRepo,
        _clock = clock ?? DateTime.now;

  final EmbeddingExtractor _extractor;
  final FaceMatchingService _matcher;
  final LastVerifiedSink _userSink;
  final VerificationLogRepository _logRepo;
  final DateTime Function() _clock;

  Future<VerifyDecision> call({
    required Uint8List rgb112,
    required FlatTemplates templates,
  }) async {
    final start = _clock();
    final stopwatch = Stopwatch()..start();

    // Empty bank short-circuit — skip the isolate call entirely. Cheaper
    // and keeps the verification log clean of error rows when the user has
    // simply not enrolled anyone.
    if (templates.isEmpty) {
      final latency = stopwatch.elapsedMilliseconds;
      await _logRepo.append(
        VerificationLog(
          userId: null,
          at: start,
          outcome: VerificationOutcome.denied,
          failureReason: VerificationFailure.noMatch.wireName,
          bestSimilarity: null,
          latencyMs: latency,
        ),
      );
      return VerifyDenied(
        reason: VerificationFailure.noMatch,
        bestSimilarity: null,
        latencyMs: latency,
      );
    }

    final Float32List probe;
    try {
      probe = await _extractor.extract(rgb112);
    } on EmbeddingFailedError {
      // Worker reported a clean inference failure (bad bytes, NaN output).
      return _logAndDeny(
        start,
        stopwatch,
        VerificationOutcome.error,
        VerificationFailure.extractionFailed,
        bestSimilarity: null,
      );
    } on Object {
      // Anything else (busy, isolate-unavailable, runtime exception) maps
      // to a generic `error` outcome. The adapter that satisfies
      // [EmbeddingExtractor] is expected to translate spawn / queue
      // exceptions into [EmbeddingFailedError] when they should be tracked
      // separately; otherwise we record the attempt and move on without
      // crashing the controller.
      return _logAndDeny(
        start,
        stopwatch,
        VerificationOutcome.error,
        VerificationFailure.error,
        bestSimilarity: null,
      );
    }

    // Per-user best-similarity scan. The matcher groups all templates
    // by their owning user before picking a winner so the runner-up gap
    // (margin) is computed across *users*, not templates of the same
    // user. This is what makes multi-user identification reliable.
    final result = _matcher.findBestUser(
      probe,
      templates.flat,
      templates.userOf,
      templates.count,
      uniqueUserCount: templates.uniqueUserCount,
    );

    if (!result.hasResult) {
      return _logAndDeny(
        start,
        stopwatch,
        VerificationOutcome.denied,
        VerificationFailure.noMatch,
        bestSimilarity: null,
      );
    }

    final best = result.bestSimilarity;
    final margin = result.margin;
    final clearsThreshold = best >= FaceThresholds.verifyThreshold;
    final clearsMargin = margin >= FaceThresholds.verifyUserMargin;

    if (clearsThreshold && clearsMargin) {
      final user = templates.uniqueUsers[result.userIndex];
      await _userSink.touchLastVerified(user.userId, start);
      final latency = stopwatch.elapsedMilliseconds;
      await _logRepo.append(
        VerificationLog(
          userId: user.userId,
          at: start,
          outcome: VerificationOutcome.granted,
          bestSimilarity: best,
          latencyMs: latency,
        ),
      );
      return VerifyGranted(
        user: user,
        similarity: best,
        latencyMs: latency,
      );
    }

    // Either the best similarity fell short OR a runner-up user is too
    // close — both surface as `noMatch` to the user. We still record
    // the `best` so threshold/margin tuning has data to learn from.
    return _logAndDeny(
      start,
      stopwatch,
      VerificationOutcome.denied,
      VerificationFailure.noMatch,
      bestSimilarity: best,
    );
  }

  Future<VerifyDecision> _logAndDeny(
    DateTime start,
    Stopwatch stopwatch,
    String outcome,
    VerificationFailure reason, {
    required double? bestSimilarity,
  }) async {
    final latency = stopwatch.elapsedMilliseconds;
    await _logRepo.append(
      VerificationLog(
        userId: null,
        at: start,
        outcome: outcome,
        failureReason: reason.wireName,
        bestSimilarity: bestSimilarity,
        latencyMs: latency,
      ),
    );
    return VerifyDenied(
      reason: reason,
      bestSimilarity: bestSimilarity,
      latencyMs: latency,
    );
  }
}
