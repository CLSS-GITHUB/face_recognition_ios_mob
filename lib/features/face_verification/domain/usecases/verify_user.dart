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
        // Default to UTC so verification_log rows + lastVerifiedAt
        // round-trip through Drift's epoch-seconds storage with a
        // consistent timezone basis. Tests inject explicit UTC clocks
        // already; this aligns the production default with that contract.
        _clock = clock ?? (() => DateTime.now().toUtc());

  final EmbeddingExtractor _extractor;
  final FaceMatchingService _matcher;
  final LastVerifiedSink _userSink;
  final VerificationLogRepository _logRepo;
  final DateTime Function() _clock;

  /// Runs the verify pipeline. Exactly one of [rgb112] or [embedding] must
  /// be supplied:
  /// - [rgb112] (slow path): the use case extracts the embedding inside
  ///   the isolate. Used when the controller has no cached probe.
  /// - [embedding] (fast path, O-5): the caller has already extracted the
  ///   probe via a speculative pre-extract during liveness; we skip the
  ///   isolate round-trip and head straight to matching. The same
  ///   defense-in-depth zeroing applies on exit so the live vector is
  ///   wiped after the match.
  Future<VerifyDecision> call({
    Uint8List? rgb112,
    Float32List? embedding,
    required FlatTemplates templates,
    double? padScore,
  }) async {
    assert(
      (rgb112 == null) != (embedding == null),
      'Provide exactly one of rgb112 or embedding',
    );
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
          padScore: padScore,
          latencyMs: latency,
        ),
      );
      return VerifyDenied(
        reason: VerificationFailure.noMatch,
        bestSimilarity: null,
        latencyMs: latency,
      );
    }

    Float32List probe;
    if (embedding != null) {
      // Fast path — caller (controller) pre-extracted the probe during
      // the liveness phase. The probe still lands in `finally` below so
      // its bytes are wiped before this function returns.
      probe = embedding;
    } else {
      try {
        probe = await _extractor.extract(rgb112!);
      } on EmbeddingFailedError {
        // Worker reported a clean inference failure (bad bytes, NaN output).
        return _logAndDeny(
          start,
          stopwatch,
          VerificationOutcome.error,
          VerificationFailure.extractionFailed,
          bestSimilarity: null,
          padScore: padScore,
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
          padScore: padScore,
        );
      }
    }

    // Defense-in-depth: zero the live probe embedding before this
    // function returns so a memory-scraper cannot recover it from the
    // heap after a verify attempt. Stored templates remain on disk
    // encrypted; the in-RAM **live** embedding is the most sensitive
    // artefact in the pipeline and is no longer needed past the match.
    try {
      // Per-user best-similarity scan. The matcher groups all templates
      // by their owning user before picking a winner so the runner-up
      // gap (margin) is computed across *users*, not templates of the
      // same user. This is what makes multi-user identification reliable.
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
          padScore: padScore,
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
            padScore: padScore,
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
        padScore: padScore,
      );
    } finally {
      // Cheap (~192 stores) and runs on every exit path including
      // exceptions. The Float32List backing buffer is the same one the
      // isolate sent over the SendPort, so this also clears the
      // worker's last result before the next extract reuses it.
      for (var i = 0; i < probe.length; i++) {
        probe[i] = 0;
      }
    }
  }

  Future<VerifyDecision> _logAndDeny(
    DateTime start,
    Stopwatch stopwatch,
    String outcome,
    VerificationFailure reason, {
    required double? bestSimilarity,
    required double? padScore,
  }) async {
    final latency = stopwatch.elapsedMilliseconds;
    await _logRepo.append(
      VerificationLog(
        userId: null,
        at: start,
        outcome: outcome,
        failureReason: reason.wireName,
        bestSimilarity: bestSimilarity,
        padScore: padScore,
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
