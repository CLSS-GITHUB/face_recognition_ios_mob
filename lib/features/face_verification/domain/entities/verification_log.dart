import 'verification_failure.dart';

/// Domain shape of one row in `verification_logs`. Created and persisted by
/// the `VerifyUser` use case; consumed by the Manage Users screen.
///
/// Wire schema is documented in
/// `docs/verification/architecture_recommendations.md` §5.1. `userId` is
/// nullable because no-match and spoof rows have no associated user.
class VerificationLog {
  const VerificationLog({
    required this.userId,
    required this.at,
    required this.outcome,
    required this.latencyMs,
    this.failureReason,
    this.bestSimilarity,
    this.padScore,
  });

  final String? userId;
  final DateTime at;

  /// One of the [VerificationOutcome] string values.
  final String outcome;

  /// Set when [outcome] is anything other than `granted`. The string form of
  /// a [VerificationFailure] (`failure.wireName`) so the column can grow
  /// new values without a schema bump.
  final String? failureReason;

  /// Best cosine similarity at decision time, if the pipeline got that far.
  /// Bounded `[-1, 1]`. Never the embedding.
  final double? bestSimilarity;

  /// F-10 instrumentation. Spoof score in `[0, 1]` from the passive PAD
  /// classifier — `0.0` = real / live, `1.0` = strongly spoofed. NULL
  /// when PAD did not run on this attempt (per-frame quality / motion
  /// gates that short-circuit before the embedding extractor, or the
  /// classifier itself raised [PadUnavailableError]). With the default
  /// [NoOpPadClassifier] this is `0.0` for every row that reached the
  /// PAD step. Persisted so a future calibration study can compute
  /// FRR/FAR on the deployment population without re-collecting data.
  final double? padScore;

  final int latencyMs;
}

/// String values used by [VerificationLog.outcome]. Kept as constants — not
/// an enum — so the data layer can persist them as TEXT without a mapper.
class VerificationOutcome {
  VerificationOutcome._();
  static const String granted = 'granted';
  static const String denied = 'denied';
  static const String error = 'error';
  static const String rateLimited = 'rateLimited';
  static const String spoof = 'spoof';
  static const String timeout = 'timeout';
}
