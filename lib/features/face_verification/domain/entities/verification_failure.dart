/// Wire-stable, exhaustive set of reasons a verification attempt can be
/// rejected or short-circuited. Persisted as the `failure_reason` column on
/// `verification_logs`, so adding new values is fine but **do not rename**.
///
/// Cross-reference: `docs/verification/architecture_recommendations.md`
/// §3.1, §5.1.
enum VerificationFailure {
  /// More than one face in the frame.
  multiFace,

  /// No face in the frame.
  noFace,

  /// `QualityAssessor.assess()` rejected (brightness, centering, pose, …).
  qualityFailed,

  /// `OcclusionDetector` rejected (sunglasses, mask, hand, …).
  occluded,

  /// Brightness below `lowLightBrightness`.
  lowLight,

  /// Mandatory blink not yet observed.
  blinkRequired,

  /// Anti-replay heuristic fired (motion variance, screen reflection, …).
  spoof,

  /// Embedding extracted, but no template cleared `verifyThreshold`.
  noMatch,

  /// Embedding pipeline raised — bad bytes, NaN output, etc.
  extractionFailed,

  /// Catch-all unexpected error (isolate down, busy, runtime exception).
  error,

  /// Watchdog fired — no decision within `verifyTimeoutMs`.
  timeout,

  /// Rate limiter cooldown blocked the attempt.
  rateLimited;

  /// Stable identifier persisted in the verification log. We use the Dart
  /// enum `name` (e.g. `multiFace`) so it can be parsed back without a
  /// custom mapping.
  String get wireName => name;
}
