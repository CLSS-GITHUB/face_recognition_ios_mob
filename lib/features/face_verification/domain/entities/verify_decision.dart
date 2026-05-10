import 'user.dart';
import 'verification_failure.dart';

/// Sealed result of `VerifyUser`. The use case returns exactly one of the
/// two subtypes; the controller pattern-switches to drive the UI.
///
/// `latencyMs` is the wall-clock duration the use case spent (extract +
/// match + bookkeeping). It's recorded both on the decision and in the
/// verification log.
sealed class VerifyDecision {
  const VerifyDecision({required this.latencyMs});
  final int latencyMs;
}

class VerifyGranted extends VerifyDecision {
  const VerifyGranted({
    required this.user,
    required this.similarity,
    required super.latencyMs,
  });

  final User user;

  /// Cosine similarity of the matched template, in `[verifyThreshold, 1]`.
  final double similarity;
}

class VerifyDenied extends VerifyDecision {
  const VerifyDenied({
    required this.reason,
    required this.bestSimilarity,
    required super.latencyMs,
  });

  final VerificationFailure reason;

  /// Best cosine similarity observed across the candidate bank, if the
  /// pipeline got far enough to produce one. Useful for tuning thresholds —
  /// **never** the embedding itself.
  final double? bestSimilarity;
}
