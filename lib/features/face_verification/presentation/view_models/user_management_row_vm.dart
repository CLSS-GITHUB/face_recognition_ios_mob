import '../../domain/entities/user.dart';

/// Presentation-only DTO for one row in the Manage Users list. Built by the
/// `userManagementRowsProvider` from `UserRepository.watchAll()` joined with
/// per-user aggregates from `VerificationLogDao`.
///
/// Intentionally NOT in the domain layer — see
/// `docs/verification/architecture_recommendations.md` §4.2.
class UserManagementRowVm {
  const UserManagementRowVm({
    required this.user,
    required this.verificationsToday,
    required this.lastOutcome,
    required this.lastVerificationAt,
  });

  final User user;

  /// Count of `verification_logs` rows for this user since local midnight.
  final int verificationsToday;

  /// Outcome of the most recent log row for this user, e.g. "granted",
  /// "denied". Null when the user has no log rows yet.
  final String? lastOutcome;

  /// Timestamp of the most recent log row, regardless of outcome. May
  /// differ from `user.lastVerifiedAt`, which only reflects granted
  /// attempts.
  final DateTime? lastVerificationAt;
}
