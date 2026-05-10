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
