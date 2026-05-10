import 'package:drift/drift.dart' show Value;

import '../../../../data/database/app_database.dart';
import '../../../../data/database/daos/verification_log_dao.dart';
import '../../domain/entities/verification_log.dart';
import '../../domain/repositories/verification_log_repository.dart';

/// Drift-backed [VerificationLogRepository]. Maps the domain
/// [VerificationLog] to / from `verification_logs` rows.
///
/// See `docs/verification/architecture_recommendations.md` §5.
class VerificationLogRepositoryImpl implements VerificationLogRepository {
  VerificationLogRepositoryImpl(this._dao);

  final VerificationLogDao _dao;

  @override
  Future<void> append(VerificationLog log) async {
    await _dao.insertLog(
      VerificationLogsCompanion.insert(
        userId: Value(log.userId),
        at: log.at,
        outcome: log.outcome,
        failureReason: Value(log.failureReason),
        bestSimilarity: Value(log.bestSimilarity),
        latencyMs: log.latencyMs,
      ),
    );
  }

  @override
  Future<int> purgeOlderThan(DateTime cutoff) =>
      _dao.purgeOlderThan(cutoff);
}
