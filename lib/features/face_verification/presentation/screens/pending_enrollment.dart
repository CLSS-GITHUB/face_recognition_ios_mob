/// Bag passed from `EnrollFormScreen` to `LiveEnrollmentScreen` via
/// `GoRouterState.extra`. Used as the default values inside the
/// RegistrationDialog so the user doesn't re-type the same fields.
class PendingEnrollment {
  const PendingEnrollment({
    required this.userCode,
    required this.userName,
    this.wearsGlasses = false,
  });
  final String userCode;
  final String userName;

  /// User's self-reported "I'm wearing glasses right now" state at
  /// enrol time. Threaded through to `EnrollUser` so the captured
  /// template's metadata records the glasses state. The matcher does
  /// not branch on this — it just becomes part of the candidate set
  /// — but the UX uses it to suggest a complementary capture later.
  final bool wearsGlasses;
}
