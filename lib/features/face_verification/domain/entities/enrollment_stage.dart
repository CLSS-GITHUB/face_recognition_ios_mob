/// Enrollment progresses through three stages, mirroring EnrollmentScreen.kt.
enum EnrollmentStage {
  /// 5-step active liveness with primary embedding capture.
  liveness,

  /// Mandatory blink + secondary embedding match against the captured one.
  verify,

  /// Final dialog to collect user details and persist via UserRepository.
  registration,
}
