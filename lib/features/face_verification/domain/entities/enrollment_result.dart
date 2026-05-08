import 'user.dart';

/// Outcome of `EnrollUser` use case. The screen uses this to pick a status
/// message after the registration dialog completes.
sealed class EnrollmentResult {
  const EnrollmentResult();
}

class NewUserEnrolled extends EnrollmentResult {
  const NewUserEnrolled(this.user);
  final User user;
}

class TemplateAddedToExisting extends EnrollmentResult {
  const TemplateAddedToExisting(this.user);
  final User user;
}

class DuplicateTemplateSkipped extends EnrollmentResult {
  const DuplicateTemplateSkipped(this.user);
  final User user;
}
