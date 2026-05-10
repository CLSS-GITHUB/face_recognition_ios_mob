/// Narrow port for stamping `users.lastVerifiedAt` on a successful verify.
///
/// Defined as its own port (rather than added to `UserRepository`) so the
/// `VerifyUser` use case can be tested with a tiny fake, and so we do not
/// have to grow `UserRepository`'s contract before the wiring slice lands.
/// In production this is satisfied by an adapter over `UserDao`.
abstract class LastVerifiedSink {
  Future<void> touchLastVerified(String userId, DateTime when);
}
