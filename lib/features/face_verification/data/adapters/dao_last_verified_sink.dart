import '../../../../data/database/daos/user_dao.dart';
import '../../domain/ports/last_verified_sink.dart';

/// Adapter from [LastVerifiedSink] port to the Drift `UserDao`.
class DaoLastVerifiedSink implements LastVerifiedSink {
  DaoLastVerifiedSink(this._dao);

  final UserDao _dao;

  @override
  Future<void> touchLastVerified(String userId, DateTime when) async {
    await _dao.touchLastVerified(userId, when);
  }
}
