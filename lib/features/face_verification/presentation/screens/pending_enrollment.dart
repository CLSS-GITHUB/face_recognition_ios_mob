/// Bag passed from `EnrollFormScreen` to `LiveEnrollmentScreen` via
/// `GoRouterState.extra`. Used as the default values inside the
/// RegistrationDialog so the user doesn't re-type the same fields.
class PendingEnrollment {
  const PendingEnrollment({required this.userCode, required this.userName});
  final String userCode;
  final String userName;
}
